import Foundation

/// Guest operating system families the app knows how to run.
enum GuestOS: String, Codable, CaseIterable {
    case linux
    case macOS
    /// Runs on the QEMU engine (HVF acceleration, TPM, Windows-compatible devices) because
    /// Virtualization.framework cannot run Windows.
    case windows

    var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        }
    }

    var symbolName: String {
        switch self {
        case .linux: return "terminal"
        case .macOS: return "apple.logo"
        case .windows: return "pc"
        }
    }

    var usesQEMU: Bool { self == .windows }
}

/// How a QEMU (Windows) guest sees its disks.
enum QEMUDiskBus: String, Codable {
    /// Emulated NVMe, which Windows drives with its in-box driver.
    case nvme
    /// NVMe boot disk plus a small virtio disk, so Windows binds its virtio storage driver
    /// (a boot-start driver) before the boot disk itself moves to virtio. Moving it first
    /// would stop Windows at INACCESSIBLE_BOOT_DEVICE.
    case preparingVirtio
    /// virtio-blk on a dedicated I/O thread; needs the virtio-win storage driver. A small
    /// spare NVMe disk stays attached so Windows can still boot from NVMe after switching back.
    case virtio
}

/// How a QEMU (Windows) guest shows its screen.
enum QEMUDisplay: String, Codable {
    /// ramfb, a plain framebuffer Windows drives with its Basic Display driver: 1024 × 768 at most.
    case basic
    /// ramfb plus virtio-gpu, so Windows binds the virtio-win display driver while the screen
    /// it already uses keeps working. QEMUMachine watches for the driver to load.
    case preparingVirtio
    /// virtio-gpu at `displayWidth` × `displayHeight`; needs the virtio-win display driver.
    /// ramfb stays attached while an ISO is: Windows' "Press any key" boot prompt and Setup
    /// can only draw on a plain framebuffer.
    case virtio
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
    /// QEMU engine only; nil means NVMe.
    var diskBus: QEMUDiskBus?
    /// QEMU engine only; nil means basic.
    var display: QEMUDisplay?
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
        case displayWidth, displayHeight, diskBus, display, sourcePVMPath, importedAt
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
    static let consoleInput = "console.in"

    /// QEMU engine: UEFI variable store, swtpm state, and the answer-file drive for Windows Setup.
    static let qemuVariableStore = "QEMU_VARS.fd"
    static let tpmState = "TPM"
    static let windowsSetup = "WindowsSetup"
    static let qemuLog = "qemu.log"
    /// Small blank spare disk for Windows VMs using (or switching to) virtio, see `QEMUDiskBus`.
    static let virtioProbe = "VirtioProbe.img"

    static func disk(_ index: Int) -> String { "disk\(index).img" }
}
