import Combine
import Foundation

/// One running QEMU guest: the swtpm and qemu-system-aarch64 child processes plus the QMP
/// connection that controls them. Mirrors the parts of `VZVirtualMachine` the app uses.
@MainActor
final class QEMUMachine: ObservableObject {
    enum Status { case starting, running, paused, stopping, stopped }

    @Published private(set) var status: Status = .starting
    let run: QEMUCommandBuilder.RunPaths
    /// Called once when the guest has exited, with an error message if it did not shut down cleanly.
    var onExit: ((String?) -> Void)?
    /// Called once when Windows has loaded the virtio storage driver for the probe disk.
    var onVirtioDriverLoaded: (() -> Void)?
    /// Called once when Windows has loaded the virtio display driver.
    var onVirtioDisplayLoaded: (() -> Void)?

    private let launch: QEMUCommandBuilder.Output
    private let tools: QEMUTools
    private let directory: URL
    private let record: VMRecord
    private var qemu: Process?
    private var swtpm: Process?
    private var qmp: QMPClient?
    private var guestRequestedShutdown = false
    private var exited = false
    /// QEMU device id of the ISO drive that's plugged in, if any.
    private var mediaDevice: String?
    private var mediaNode: String?
    private var mediaCounter = 0
    nonisolated static let bootMediaDevice = "bootcd"

    init(record: VMRecord, directory: URL, tools: QEMUTools) throws {
        self.record = record
        self.directory = directory
        self.tools = tools
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvm-" + record.id.uuidString.prefix(8).lowercased())
        try? FileManager.default.removeItem(at: runDirectory)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        run = QEMUCommandBuilder.RunPaths(directory: runDirectory)
        launch = try QEMUCommandBuilder.build(record: record, directory: directory, run: run, tools: tools)
    }

    var effectiveNetworkMode: NetworkMode { launch.effectiveNetworkMode }
    var notices: [String] { launch.notices }
    var isoAttached: Bool { launch.isoAttached }
    var screens: QEMUCommandBuilder.Screens { launch.screens }

    func start() async throws {
        let log = try openLog()
        try await startTPM(log: log)

        let process = Process()
        process.executableURL = tools.qemu
        process.arguments = launch.arguments
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.qemuExited(status: status) }
        }
        try process.run()
        qemu = process

        let client = try await connectQMP(process: process)
        client.onEvent = { [weak self] event, _ in
            Task { @MainActor in self?.handle(event: event) }
        }
        qmp = client
        mediaDevice = launch.isoAttached ? Self.bootMediaDevice : nil
        status = .running
        if launch.isoAttached && Self.diskIsBlank(directory.appendingPathComponent(record.diskFileNames.first ?? "")) {
            pressKeyThroughBootPrompt()
        }
        if record.diskBus == .preparingVirtio {
            watchVirtioProbe()
        }
        if record.display == .preparingVirtio {
            watchDisplayDriver()
        }
    }

    func pause() async throws {
        try await qmp?.execute("stop")
    }

    func resume() async throws {
        try await qmp?.execute("cont")
    }

    /// Presses the virtual power button; Windows shuts down cleanly.
    func requestStop() async throws {
        try await qmp?.execute("system_powerdown")
    }

    /// Ends QEMU immediately, like pulling the plug.
    func forceStop() {
        status = .stopping
        if let qmp {
            Task { try? await qmp.execute("quit") }
        }
        let process = qemu
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    /// Synchronous kill for app termination.
    func terminateNow() {
        qemu?.terminate()
        swtpm?.terminate()
    }

    /// Hot-plugs an ISO as a USB CD drive (usb-bot + scsi-cd, so Windows reads its UDF file
    /// system), replacing any drive already plugged in.
    func attachMedia(_ url: URL) async throws {
        guard let qmp else { throw QMPError.disconnected }
        try await ejectMedia()
        mediaCounter += 1
        let node = "media\(mediaCounter)", bot = "mediabot\(mediaCounter)"
        try await qmp.execute("blockdev-add", arguments: [
            "node-name": node, "driver": "raw", "read-only": true,
            "file": ["driver": "file", "filename": url.path, "read-only": true],
        ])
        do {
            // A hot-plugged usb-bot stays detached until its LUNs are added and it's switched on.
            try await qmp.execute("device_add", arguments: ["driver": "usb-bot", "id": bot])
            try await qmp.execute("device_add", arguments: ["driver": "scsi-cd", "id": "\(bot)-cd", "bus": "\(bot).0", "drive": node])
            try await qmp.execute("qom-set", arguments: ["path": bot, "property": "attached", "value": true])
        } catch {
            _ = try? await qmp.execute("device_del", arguments: ["id": bot])
            _ = try? await qmp.execute("blockdev-del", arguments: ["node-name": node])
            throw error
        }
        mediaDevice = bot
        mediaNode = node
    }

    /// Unplugs the ISO drive, whether it was attached at start or while running.
    func ejectMedia() async throws {
        guard let qmp, let device = mediaDevice else { return }
        try await qmp.execute("device_del", arguments: ["id": device])
        mediaDevice = nil
        if let node = mediaNode {
            mediaNode = nil
            // The node is released once the guest lets go of the device.
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if (try? await qmp.execute("blockdev-del", arguments: ["node-name": node])) != nil { return }
                }
            }
        }
    }

    /// USB devices on the virtual controller (QEMU's `info usb`), for diagnostics and tests.
    func usbDevices() async -> String {
        let result = try? await qmp?.execute("human-monitor-command", arguments: ["command-line": "info usb"])
        return result as? String ?? ""
    }

    /// Whether the hot-plugged ISO drive is switched on for the guest.
    var isMediaAttached: Bool {
        get async {
            guard let device = mediaDevice, device != Self.bootMediaDevice else { return mediaDevice != nil }
            let result = try? await qmp?.execute("qom-get", arguments: ["path": device, "property": "attached"])
            return result as? Bool ?? false
        }
    }

    func sendKey(_ qcode: String) async {
        _ = try? await qmp?.execute("send-key", arguments: ["keys": [["type": "qcode", "data": qcode]]])
    }

    // MARK: - Internals

    private func openLog() throws -> FileHandle {
        let url = directory.appendingPathComponent(VMFiles.qemuLog)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private func startTPM(log: FileHandle) async throws {
        let state = directory.appendingPathComponent(VMFiles.tpmState)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: run.tpmState, withDestinationPath: state.path)
        let process = Process()
        process.executableURL = tools.swtpm
        process.arguments = ["socket", "--tpm2", "--tpmstate", "dir=\(run.tpmState)",
                             "--ctrl", "type=unixio,path=\(run.tpm)", "--terminate"]
        process.standardOutput = log
        process.standardError = log
        try process.run()
        swtpm = process
        // QEMU fails to start if the TPM socket isn't there yet.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: run.tpm) { return }
            guard process.isRunning else { throw QEMUMachineError.tpmFailed(lastLogLines()) }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw QEMUMachineError.tpmFailed(lastLogLines())
    }

    private func connectQMP(process: Process) async throws -> QMPClient {
        var lastError: Error = QMPError.connectFailed("timed out")
        for _ in 0..<100 {
            guard process.isRunning else { throw QEMUMachineError.exited(lastLogLines()) }
            if FileManager.default.fileExists(atPath: run.qmp) {
                do {
                    // Connecting and the greeting use blocking socket calls; keep them off the main actor.
                    let path = run.qmp
                    return try await Task.detached {
                        let client = try QMPClient(socketPath: path)
                        try client.handshake()
                        return client
                    }.value
                } catch {
                    lastError = error
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw lastError
    }

    private func handle(event: String) {
        switch event {
        case "STOP": if status == .running { status = .paused }
        case "RESUME": if status == .paused || status == .starting { status = .running }
        case "SHUTDOWN": guestRequestedShutdown = true; status = .stopping
        case "POWERDOWN": status = .stopping
        default: break
        }
    }

    private func qemuExited(status exitStatus: Int32) {
        guard !exited else { return }
        exited = true
        swtpm?.terminate()
        qmp?.disconnect()
        qmp = nil
        status = .stopped
        try? FileManager.default.removeItem(at: run.directory)
        let clean = exitStatus == 0 || guestRequestedShutdown || exitStatus == SIGTERM
        onExit?(clean ? nil : QEMUMachineError.exited(lastLogLines()).localizedDescription)
    }

    /// The Windows ISO's boot manager waits a few seconds for a key before falling through to
    /// the (still empty) disk. On a fresh VM, press it so Setup starts by itself.
    private func pressKeyThroughBootPrompt() {
        Task {
            for _ in 0..<30 {
                guard status == .running else { return }
                await sendKey("spc")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The probe disk's request queue stays untouched until a guest driver uses it: the
    /// firmware only opens disks in the boot order, so any completed request is Windows'.
    private func watchVirtioProbe() {
        Task {
            while status != .stopping && status != .stopped {
                if await virtioQueueUsed(device: QEMUCommandBuilder.virtioProbeDevice, queue: 0) > 0 {
                    onVirtioDriverLoaded?()
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The firmware drives virtio-gpu too, then resets it when Windows takes over. Requests
    /// after that reset (the count dropping) come from Windows' own display driver.
    private func watchDisplayDriver() {
        Task {
            var last = 0, reset = false
            while status != .stopping && status != .stopped {
                let used = await virtioQueueUsed(device: "gpu", queue: 0)
                if used < last { reset = true }
                if reset && used > 0 {
                    onVirtioDisplayLoaded?()
                    return
                }
                last = used
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Requests completed on a virtio device's queue since its driver set it up.
    func virtioQueueUsed(device: String, queue: Int) async -> Int {
        let path = "/machine/peripheral/\(device)/virtio-backend"
        let result = try? await qmp?.execute("x-query-virtio-queue-status", arguments: ["path": path, "queue": queue])
        return (result as? [String: Any])?["used-idx"] as? Int ?? 0
    }

    /// True when the disk has no partition table yet (nothing installed).
    static func diskIsBlank(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 512)
        return handle.readData(ofLength: 8) != Data("EFI PART".utf8)
    }

    private func lastLogLines() -> String {
        let url = directory.appendingPathComponent(VMFiles.qemuLog)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(4).joined(separator: "\n")
    }
}

enum QEMUMachineError: LocalizedError {
    case exited(String)
    case tpmFailed(String)

    var errorDescription: String? {
        switch self {
        case .exited(let log):
            return log.isEmpty ? "QEMU exited unexpectedly." : "QEMU exited unexpectedly:\n\(log)"
        case .tpmFailed(let log):
            return "The virtual TPM (swtpm) failed to start.\n\(log)"
        }
    }
}
