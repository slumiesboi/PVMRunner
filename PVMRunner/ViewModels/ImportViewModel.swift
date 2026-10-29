import Foundation
import Virtualization

/// Drives the import flow: parse the .pvm, show the summary, convert disks, write the VM folder.
@MainActor
final class ImportViewModel: ObservableObject {
    enum Phase {
        case idle
        case summary
        case converting
        case failed(message: String, suggestion: String?)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var parsed: ParsedPVM?

    // Editable summary fields
    @Published var name = ""
    @Published var cpuCount = 2
    @Published var memoryMB = 2048
    @Published var networkMode: NetworkMode = .nat
    @Published var bridgedInterfaceID: String?
    @Published var resizeEnabled = false
    @Published var resizeGB = 64

    // Conversion progress
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressMessage = ""

    private var importTask: Task<Void, Never>?
    private let store = VMLibraryStore()
    private let converter = DiskConverter()

    var isPresented: Bool {
        if case .idle = phase { return false }
        return true
    }

    var needsQemuImg: Bool {
        parsed?.disks.contains { $0.format == .parallels || $0.imageURL.pathExtension.lowercased() == "hds" } ?? false
    }

    var qemuImgMissing: Bool {
        needsQemuImg && DiskConverter.locateQemuImg() == nil
    }

    /// Current size of the boot disk in whole GB, used as the lower bound for resizing.
    var bootDiskGB: Int {
        let bytes = parsed?.disks.first?.virtualSize ?? 0
        return max(1, Int((Double(bytes) / 1_073_741_824).rounded(.up)))
    }

    static func isImportable(_ url: URL) -> Bool {
        ["pvm", "macvm"].contains(url.pathExtension.lowercased())
    }

    func open(_ url: URL) {
        guard !isConverting else { return }
        guard Self.isImportable(url) else {
            phase = .failed(message: "“\(url.lastPathComponent)” is not a Parallels virtual machine.",
                            suggestion: "Choose a .pvm bundle, usually found in ~/Parallels.")
            return
        }
        do {
            let result = try PVMParser().parse(bundleURL: url)
            parsed = result
            name = result.name
            cpuCount = HostLimits.clampCPU(result.cpuCount)
            memoryMB = HostLimits.clampMemoryMB(result.memoryMB)
            bridgedInterfaceID = nil
            // Keep a VM that was bridged in Parallels on the LAN when the socket_vmnet helper is up.
            let wasBridged = result.networkAdapters.contains { $0.parallelsMode == "Bridged" }
            networkMode = wasBridged && SocketVmnetRelay.isReachable(path: SocketVmnetRelay.defaultSocketPath(interface: "en0"))
                ? .socketVmnet : .nat
            resizeEnabled = false
            resizeGB = max(bootDiskGB, 64)
            phase = .summary
        } catch {
            parsed = nil
            phase = .failed(message: error.localizedDescription, suggestion: nil)
        }
    }

    var isConverting: Bool {
        if case .converting = phase { return true }
        return false
    }

    func cancel() {
        if let importTask {
            importTask.cancel()
        } else {
            reset()
        }
    }

    func dismiss() {
        importTask?.cancel()
        reset()
    }

    private func reset() {
        importTask = nil
        parsed = nil
        progress = 0
        progressMessage = ""
        phase = .idle
    }

    func confirm(onImported: @escaping (VMRecord) -> Void) {
        guard let parsed, parsed.unsupportedReason == nil else { return }
        if qemuImgMissing {
            phase = .failed(message: DiskConverterError.qemuImgMissing.errorDescription ?? "",
                            suggestion: DiskConverterError.qemuImgMissing.recoverySuggestion)
            return
        }
        phase = .converting
        progress = 0
        let settings = (name: name.trimmingCharacters(in: .whitespaces).isEmpty ? parsed.name : name,
                        cpu: cpuCount, memory: memoryMB, network: networkMode, interface: bridgedInterfaceID,
                        resizeBytes: resizeEnabled ? UInt64(resizeGB) * 1_073_741_824 : nil)

        importTask = Task {
            var directoryName: String?
            do {
                let folder = try store.makeDirectory(forVMNamed: settings.name)
                directoryName = folder
                let record = try await performImport(parsed, folder: folder, settings: settings)
                try store.save(record)
                importTask = nil
                reset()
                onImported(record)
            } catch {
                if let directoryName { store.removeDirectory(named: directoryName) }
                importTask = nil
                if Task.isCancelled || error is CancellationError {
                    reset()
                } else {
                    phase = .failed(message: error.localizedDescription,
                                    suggestion: (error as? LocalizedError)?.recoverySuggestion)
                }
            }
        }
    }

    private func performImport(
        _ parsed: ParsedPVM, folder: String,
        settings: (name: String, cpu: Int, memory: Int, network: NetworkMode, interface: String?, resizeBytes: UInt64?)
    ) async throws -> VMRecord {
        let directory = store.rootURL.appendingPathComponent(folder)
        let guestOS: GuestOS = parsed.guestOS == .macOS ? .macOS : .linux

        if guestOS == .macOS, let platform = parsed.macPlatform {
            progressMessage = "Copying macOS platform files…"
            try installMacPlatform(platform, into: directory)
        }

        var diskNames: [String] = []
        let total = Double(parsed.disks.count)
        for (index, disk) in parsed.disks.enumerated() {
            let fileName = VMFiles.disk(index)
            progressMessage = "Converting \(disk.displayName) (\(index + 1) of \(parsed.disks.count))…"
            try await converter.convert(source: disk.imageURL, format: disk.format,
                                        to: directory.appendingPathComponent(fileName)) { [weak self] value in
                Task { @MainActor in self?.progress = (Double(index) + value) / total }
            }
            try Task.checkCancellation()
            diskNames.append(fileName)
        }

        let bootDisk = directory.appendingPathComponent(diskNames[0])
        if guestOS == .linux && parsed.architecture != .arm64 {
            progressMessage = "Checking the guest architecture…"
            let result = await Task.detached { ArchitectureProbe.probe(rawImage: bootDisk) }.value
            if result.architecture == .x86 {
                throw ImportError.x86Guest(result.evidence)
            }
        }

        if let bytes = settings.resizeBytes {
            let current = UInt64((try? bootDisk.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if bytes > current {
                progressMessage = "Resizing the boot disk…"
                try await converter.resize(image: bootDisk, to: bytes)
            }
        }

        let display = guestOS == .macOS ? (2560, 1600) : (1920, 1200)
        var record = VMRecord(
            id: UUID(), name: settings.name, guestOS: guestOS,
            guestOSDescription: parsed.guestOSDescription,
            cpuCount: settings.cpu, memoryMB: settings.memory, diskFileNames: diskNames,
            networkMode: settings.network, bridgedInterfaceID: settings.interface,
            macAddress: parsed.preferredMACAddress ?? VZMACAddress.randomLocallyAdministered().string,
            isoPath: nil, displayWidth: display.0, displayHeight: display.1,
            sourcePVMPath: parsed.bundleURL.path, importedAt: Date())
        record.directoryName = folder
        return record
    }

    /// Decodes and copies the Apple platform files. The auxiliary storage is copied because
    /// the guest writes to it; the original bundle is never modified.
    private func installMacPlatform(_ platform: MacPlatformFiles, into directory: URL) throws {
        let hardwareData = try Self.decodePlatformData(contentsOf: platform.hardwareModel) {
            VZMacHardwareModel(dataRepresentation: $0) != nil
        }
        guard let model = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw ImportError.invalidMacPlatform("The hardware model file could not be decoded.")
        }
        guard model.isSupported else {
            throw ImportError.invalidMacPlatform("This Mac cannot run the guest's hardware model. Update macOS on this Mac and try again.")
        }
        let identifierData = try Self.decodePlatformData(contentsOf: platform.machineIdentifier) {
            VZMacMachineIdentifier(dataRepresentation: $0) != nil
        }
        try hardwareData.write(to: directory.appendingPathComponent(VMFiles.hardwareModel))
        try identifierData.write(to: directory.appendingPathComponent(VMFiles.machineIdentifier))
        try FileManager.default.copyItem(at: platform.auxiliaryStorage,
                                         to: directory.appendingPathComponent(VMFiles.auxiliaryStorage))
    }

    /// Platform files are stored either as the raw data representation or base64-encoded.
    private static func decodePlatformData(contentsOf url: URL, isValid: (Data) -> Bool) throws -> Data {
        let data = try Data(contentsOf: url)
        if isValid(data) { return data }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: text), isValid(decoded) {
            return decoded
        }
        throw ImportError.invalidMacPlatform("“\(url.lastPathComponent)” is not a valid Virtualization.framework platform file.")
    }
}

enum ImportError: LocalizedError {
    case x86Guest(String)
    case invalidMacPlatform(String)

    var errorDescription: String? {
        switch self {
        case .x86Guest(let evidence):
            return "This is an x86 / Intel virtual machine (\(evidence.lowercased())). Apple Silicon can only run "
                + "ARM64 guests with Virtualization.framework, so it was not imported."
        case .invalidMacPlatform(let detail):
            return "This macOS guest cannot be imported. \(detail)"
        }
    }
}
