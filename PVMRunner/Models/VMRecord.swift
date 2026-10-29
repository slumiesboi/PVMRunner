import Foundation

/// Guest operating system families the app knows how to run.
enum GuestOS: String, Codable, CaseIterable {
    case linux
    case macOS

    var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        }
    }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable {
    case nat
    case bridged
    /// Bridged through a root `socket_vmnet` helper; needs no restricted entitlement.
    case socketVmnet
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nat: return "NAT (shared)"
        case .bridged: return "Bridged (entitlement)"
        case .socketVmnet: return "Bridged (socket_vmnet)"
        case .none: return "None"
        }
    }
}

/// Persisted per-VM configuration, stored as `vm.json` next to the disk images in
/// `~/Library/Application Support/PVMRunner/VMs/<name>/`.
struct VMRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var guestOS: GuestOS
    /// Free-form OS description taken from config.pvs (e.g. "Ubuntu").
    var guestOSDescription: String
    var cpuCount: Int
    var memoryMB: Int
    /// Disk image file names, relative to the VM directory. The first one is the boot disk.
    var diskFileNames: [String]
    var networkMode: NetworkMode
    /// Host interface to bridge to (e.g. "en0"): a `VZBridgedNetworkInterface.identifier` in
    /// `.bridged` mode, or the interface socket_vmnet was started on in `.socketVmnet` mode.
    var bridgedInterfaceID: String?
    /// socket_vmnet socket path; nil means `/var/run/socket_vmnet.bridged.<interface>`.
    var socketVmnetPath: String?
    var macAddress: String
    /// Optional install / recovery ISO attached as a USB mass storage device.
    var isoPath: String?
    var displayWidth: Int
    var displayHeight: Int
    var sourcePVMPath: String
    var importedAt: Date

    /// Name of the folder inside the library directory. Not persisted; set when loading.
    var directoryName: String = ""

    var effectiveSocketVmnetPath: String {
        if let socketVmnetPath, !socketVmnetPath.isEmpty { return socketVmnetPath }
        return SocketVmnetRelay.defaultSocketPath(interface: bridgedInterfaceID ?? "en0")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, guestOS, guestOSDescription, cpuCount, memoryMB, diskFileNames
        case networkMode, bridgedInterfaceID, socketVmnetPath, macAddress, isoPath
        case displayWidth, displayHeight, sourcePVMPath, importedAt
    }
}

/// Fixed file names inside a VM directory.
enum VMFiles {
    static let record = "vm.json"
    static let efiVariableStore = "NVRAM"
    static let machineIdentifier = "MachineIdentifier"
    static let hardwareModel = "HardwareModel"
    static let auxiliaryStorage = "AuxiliaryStorage"
    static let consoleLog = "console.log"

    static func disk(_ index: Int) -> String { "disk\(index).img" }
}
