import Foundation
import Virtualization

enum VMRunState: String {
    case stopped, starting, running, pausing, paused, resuming, stopping, error

    init(_ state: VZVirtualMachine.State) {
        switch state {
        case .stopped: self = .stopped
        case .running: self = .running
        case .paused: self = .paused
        case .error: self = .error
        case .starting: self = .starting
        case .pausing: self = .pausing
        case .resuming: self = .resuming
        case .stopping: self = .stopping
        case .saving: self = .pausing
        case .restoring: self = .resuming
        @unknown default: self = .error
        }
    }

    var displayName: String { rawValue.capitalized }

    var isActive: Bool { self != .stopped && self != .error }
}

/// Owns one running `VZVirtualMachine`. The VM lives on the main queue, so every
/// interaction happens on the main actor.
@MainActor
final class VMController: NSObject, ObservableObject {
    let vmID: UUID
    @Published private(set) var state: VMRunState = .stopped
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published private(set) var effectiveNetworkMode: NetworkMode?
    @Published var errorMessage: String?
    @Published var notices: [String] = []
    /// Path of the ISO currently attached as a USB drive, if any.
    @Published private(set) var attachedMediaPath: String?
    /// True when the attached ISO was configured at start. Virtualization.framework does not
    /// expose boot-time USB storage on the controller, so it cannot be unplugged until the VM stops.
    @Published private(set) var mediaAttachedAtBoot = false

    enum EjectResult {
        /// Unplugged from the running VM.
        case ejected
        /// Attached at boot: stays in until the VM stops, and is not attached at the next start.
        case atNextStart
        case failed
    }

    private var stateObservation: NSKeyValueObservation?
    private(set) var networkRelay: SocketVmnetRelay?

    init(vmID: UUID) {
        self.vmID = vmID
    }

    var canStart: Bool { state == .stopped || state == .error }
    var canPause: Bool { virtualMachine?.canPause ?? false }
    var canResume: Bool { virtualMachine?.canResume ?? false }
    var canRequestStop: Bool { virtualMachine?.canRequestStop ?? false }
    var canForceStop: Bool { virtualMachine?.canStop ?? false }

    func start(record: VMRecord, directory: URL) async {
        guard canStart else { return }
        errorMessage = nil
        notices = []
        if let busy = Self.fileInUse(record: record, directory: directory) {
            // Without this check the framework reports a misleading "The boot loader is invalid".
            errorMessage = "“\(record.name)” is already running in another app or window "
                + "(\(busy) is locked). Shut it down there first, then start it again."
            state = .error
            return
        }
        do {
            try await boot(record: record, directory: directory, forceNAT: false)
        } catch let error where record.networkMode == .bridged && effectiveNetworkMode == .bridged {
            // The framework rejected the bridged attachment at start (e.g. entitlement not honoured).
            notices.append(VMConfigurationBuilder.bridgedFallbackMessage + " (\(error.localizedDescription))")
            do {
                try await boot(record: record, directory: directory, forceNAT: true)
            } catch {
                fail(error)
            }
        } catch {
            fail(error)
        }
    }

    /// Virtualization.framework holds an exclusive flock on a running VM's disks and EFI
    /// variable store. Returns the name of the first file another process has locked.
    static func fileInUse(record: VMRecord, directory: URL) -> String? {
        let names = record.diskFileNames + [VMFiles.efiVariableStore, VMFiles.auxiliaryStorage]
        for name in names {
            let fd = open(directory.appendingPathComponent(name).path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            if flock(fd, LOCK_SH | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK { return name }
            } else {
                flock(fd, LOCK_UN)
            }
        }
        return nil
    }

    private func boot(record: VMRecord, directory: URL, forceNAT: Bool) async throws {
        let output = try VMConfigurationBuilder.build(record: record, directory: directory, forceNAT: forceNAT)
        notices.append(contentsOf: output.notices)
        effectiveNetworkMode = output.effectiveNetworkMode
        attachedMediaPath = record.isoPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        mediaAttachedAtBoot = attachedMediaPath != nil
        networkRelay?.stop()
        networkRelay = output.relay

        let vm = VZVirtualMachine(configuration: output.configuration, queue: .main)
        vm.delegate = self
        attach(vm)
        try await vm.start()
    }

    func pause() async {
        guard let vm = virtualMachine, vm.canPause else { return }
        do { try await vm.pause() } catch { fail(error) }
    }

    func resume() async {
        guard let vm = virtualMachine, vm.canResume else { return }
        do { try await vm.resume() } catch { fail(error) }
    }

    /// Asks the guest to shut down (ACPI power button). The guest decides when to stop.
    // MARK: - Removable media

    /// Whether ISOs can be ejected and attached while the VM runs (macOS 15+).
    var supportsLiveMedia: Bool {
        guard let vm = virtualMachine, state == .running || state == .paused else { return false }
        if #available(macOS 15.0, *) { return !vm.usbControllers.isEmpty }
        return false
    }

    /// Ejects the attached ISO: unplugs it if it was hot-plugged, or drops it from the next
    /// start if it was attached at boot.
    @discardableResult
    func ejectMedia() async -> EjectResult {
        if #available(macOS 15.0, *), let usb = virtualMachine?.usbControllers.first,
           let device = usb.usbDevices.first(where: { $0 is VZUSBMassStorageDevice }) {
            do {
                try await usb.detach(device: device)
                attachedMediaPath = nil
                mediaAttachedAtBoot = false
                return .ejected
            } catch {
                errorMessage = "Could not eject the ISO: \(error.localizedDescription)"
                return .failed
            }
        }
        if mediaAttachedAtBoot { return .atNextStart }
        attachedMediaPath = nil
        return .ejected
    }

    /// Plugs an ISO or disk image into the running VM as a read-only USB drive, replacing
    /// any ISO already attached. Returns true on success.
    @discardableResult
    func attachMedia(_ url: URL) async -> Bool {
        guard #available(macOS 15.0, *), let usb = virtualMachine?.usbControllers.first else { return false }
        if usb.usbDevices.contains(where: { $0 is VZUSBMassStorageDevice }) {
            guard await ejectMedia() == .ejected else { return false }
        }
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
            let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            try await usb.attach(device: device)
            attachedMediaPath = url.path
            return true
        } catch {
            errorMessage = "Could not attach “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return false
        }
    }

    func requestStop() {
        guard let vm = virtualMachine, vm.canRequestStop else { return }
        do { try vm.requestStop() } catch { fail(error) }
    }

    /// Immediately powers off the VM, like pulling the plug.
    func forceStop() async {
        guard let vm = virtualMachine, vm.canStop else { return }
        do { try await vm.stop() } catch { fail(error) }
        teardown()
    }

    private func attach(_ vm: VZVirtualMachine) {
        stateObservation = vm.observe(\.state, options: [.initial, .new]) { [weak self] vm, _ in
            let newState = VMRunState(vm.state)
            MainActor.assumeIsolated {
                self?.state = newState
            }
        }
        virtualMachine = vm
    }

    private func teardown() {
        attachedMediaPath = nil
        mediaAttachedAtBoot = false
        stateObservation = nil
        virtualMachine = nil
        networkRelay?.stop()
        networkRelay = nil
        effectiveNetworkMode = nil
        if state != .error { state = .stopped }
    }

    private func fail(_ error: Error) {
        errorMessage = (error as NSError).localizedDescription
        if virtualMachine?.state != .running && virtualMachine?.state != .paused {
            teardown()
            state = .error
        }
    }
}

extension VMController: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { self.teardown() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.errorMessage = "The virtual machine stopped unexpectedly: \(message)"
            self.teardown()
            self.state = .error
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice,
                                    attachmentWasDisconnectedWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.notices.append("The network attachment was disconnected: \(message)")
        }
    }
}
