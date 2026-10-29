import Foundation
import Security
import Virtualization

enum VMConfigurationError: LocalizedError {
    case missingDisk(String)
    case invalidMacPlatform(String)

    var errorDescription: String? {
        switch self {
        case .missingDisk(let name):
            return "The disk image “\(name)” is missing from the VM folder."
        case .invalidMacPlatform(let detail):
            return "The macOS platform files are invalid: \(detail)"
        }
    }
}

/// Turns a persisted `VMRecord` into a validated `VZVirtualMachineConfiguration`.
enum VMConfigurationBuilder {
    struct Output {
        var configuration: VZVirtualMachineConfiguration
        var effectiveNetworkMode: NetworkMode
        /// Non-fatal messages for the user (e.g. bridged networking fell back to NAT).
        var notices: [String]
        /// Packet relay for socket_vmnet mode; must stay alive while the VM runs.
        var relay: SocketVmnetRelay?
    }

    static let networkingEntitlement = "com.apple.vm.networking"

    static var hasBridgedNetworkingEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, networkingEntitlement as CFString, nil)
        return (value as? Bool) == true
    }

    static var bridgedInterfaces: [VZBridgedNetworkInterface] {
        VZBridgedNetworkInterface.networkInterfaces
    }

    static var bridgedFallbackMessage: String {
        "Bridged networking needs the com.apple.vm.networking entitlement, which Apple must grant "
            + "to your developer team. This build does not have it, so the VM is using NAT instead. "
            + "See the README for how to request it."
    }

    static func socketVmnetFallbackMessage(path: String, error: Error) -> String {
        "\(error.localizedDescription) The VM is using NAT instead. Start the helper (see Network "
            + "settings or the README) and restart the VM to use bridged networking."
    }

    static func build(record: VMRecord, directory: URL, forceNAT: Bool = false) throws -> Output {
        var notices: [String] = []
        var relay: SocketVmnetRelay?
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = HostLimits.clampCPU(record.cpuCount)
        config.memorySize = HostLimits.clampMemoryBytes(UInt64(record.memoryMB) * 1024 * 1024)

        switch record.guestOS {
        case .linux: try configureLinux(config, record: record, directory: directory)
        case .macOS: try configureMacOS(config, record: record, directory: directory)
        }

        // Disks
        var storage: [VZStorageDeviceConfiguration] = []
        for name in record.diskFileNames {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw VMConfigurationError.missingDisk(name) }
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        if let isoPath = record.isoPath, !isoPath.isEmpty {
            let isoURL = URL(fileURLWithPath: isoPath)
            if FileManager.default.fileExists(atPath: isoURL.path) {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
                storage.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            } else {
                notices.append("The attached ISO “\(isoURL.lastPathComponent)” no longer exists and was skipped.")
            }
        }
        config.storageDevices = storage

        // Networking
        var mode = forceNAT && record.networkMode == .bridged ? .nat : record.networkMode
        if mode == .socketVmnet {
            let path = record.effectiveSocketVmnetPath
            do {
                let connected = try SocketVmnetRelay(socketPath: path)
                let device = makeNetworkDevice(record: record)
                device.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: connected.vmFileHandle)
                config.networkDevices = [device]
                relay = connected
            } catch {
                notices.append(socketVmnetFallbackMessage(path: path, error: error))
                mode = .nat
            }
        }
        if mode == .bridged {
            if !hasBridgedNetworkingEntitlement {
                notices.append(bridgedFallbackMessage)
                mode = .nat
            } else if let interface = bridgedInterfaces.first(where: { $0.identifier == record.bridgedInterfaceID })
                        ?? bridgedInterfaces.first {
                let device = makeNetworkDevice(record: record)
                device.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
                config.networkDevices = [device]
                if interface.identifier != record.bridgedInterfaceID {
                    notices.append("Bridged interface “\(record.bridgedInterfaceID ?? "none")” is not available; using \(interface.identifier).")
                }
            } else {
                notices.append("No network interface is available for bridging, so the VM is using NAT instead.")
                mode = .nat
            }
        }
        if mode == .nat {
            let device = makeNetworkDevice(record: record)
            device.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [device]
        } else if mode == .none {
            config.networkDevices = []
        }

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Serial console (hvc0 in Linux) logged to console.log in the VM folder.
        let logURL = directory.appendingPathComponent(VMFiles.consoleLog)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: logHandle)
            config.serialPorts = [serial]
        }

        do {
            try config.validate()
        } catch {
            relay?.stop()
            guard mode == .bridged else { throw error }
            // Bridged attachments can fail validation when the entitlement is not honoured.
            var output = try build(record: record, directory: directory, forceNAT: true)
            output.notices.insert(bridgedFallbackMessage + " (\(error.localizedDescription))", at: 0)
            return output
        }
        return Output(configuration: config, effectiveNetworkMode: mode, notices: notices, relay: relay)
    }

    private static func makeNetworkDevice(record: VMRecord) -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = VZMACAddress(string: record.macAddress) ?? .randomLocallyAdministered()
        return device
    }

    // MARK: - Linux

    private static func configureLinux(_ config: VZVirtualMachineConfiguration, record: VMRecord, directory: URL) throws {
        let platform = VZGenericPlatformConfiguration()
        let idURL = directory.appendingPathComponent(VMFiles.machineIdentifier)
        if let data = try? Data(contentsOf: idURL), let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            let identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: idURL)
            platform.machineIdentifier = identifier
        }
        config.platform = platform

        let storeURL = directory.appendingPathComponent(VMFiles.efiVariableStore)
        let store = FileManager.default.fileExists(atPath: storeURL.path)
            ? VZEFIVariableStore(url: storeURL)
            : try VZEFIVariableStore(creatingVariableStoreAt: storeURL)
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = store
        config.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: record.displayWidth, heightInPixels: record.displayHeight)]
        config.graphicsDevices = [graphics]

        // Virtualization.framework has no virtio input devices; USB HID is the
        // supported keyboard / absolute pointer for Linux guests.
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // SPICE agent port: clipboard sharing with spice-vdagent in the guest.
        let console = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        port.attachment = spice
        console.ports[0] = port
        config.consoleDevices = [console]

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        config.audioDevices = [sound]
    }

    // MARK: - macOS

    private static func configureMacOS(_ config: VZVirtualMachineConfiguration, record: VMRecord, directory: URL) throws {
        let platform = VZMacPlatformConfiguration()
        let hardwareData = try Data(contentsOf: directory.appendingPathComponent(VMFiles.hardwareModel))
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
            throw VMConfigurationError.invalidMacPlatform("the hardware model could not be decoded")
        }
        guard hardwareModel.isSupported else {
            throw VMConfigurationError.invalidMacPlatform("this Mac does not support the guest's hardware model; update macOS on the host")
        }
        let idData = try Data(contentsOf: directory.appendingPathComponent(VMFiles.machineIdentifier))
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw VMConfigurationError.invalidMacPlatform("the machine identifier could not be decoded")
        }
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: directory.appendingPathComponent(VMFiles.auxiliaryStorage))
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: record.displayWidth, heightInPixels: record.displayHeight, pixelsPerInch: 144)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        config.audioDevices = [sound]
    }
}

/// CPU and memory bounds accepted by Virtualization.framework on this host.
enum HostLimits {
    static var cpuRange: ClosedRange<Int> {
        let lower = max(1, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let upper = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.activeProcessorCount)
        return lower...max(lower, upper)
    }

    /// Memory range in MB, capped at the host's physical memory.
    static var memoryRangeMB: ClosedRange<Int> {
        let minimum = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, 512 * 1024 * 1024)
        let maximum = min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, ProcessInfo.processInfo.physicalMemory)
        let lower = Int(minimum / (1024 * 1024))
        return lower...max(lower, Int(maximum / (1024 * 1024)))
    }

    static func clampCPU(_ value: Int) -> Int {
        min(max(value, cpuRange.lowerBound), cpuRange.upperBound)
    }

    static func clampMemoryMB(_ value: Int) -> Int {
        min(max(value, memoryRangeMB.lowerBound), memoryRangeMB.upperBound)
    }

    static func clampMemoryBytes(_ value: UInt64) -> UInt64 {
        UInt64(clampMemoryMB(Int(value / (1024 * 1024)))) * 1024 * 1024
    }
}
