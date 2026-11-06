import Foundation

enum GuestArchitecture: String {
    case arm64
    case x86
    case unknown

    var displayName: String {
        switch self {
        case .arm64: return "ARM64"
        case .x86: return "x86 / Intel"
        case .unknown: return "Unknown"
        }
    }
}

/// Guest OS as described by config.pvs (broader than what we can run).
enum ParsedGuestOS: Equatable {
    case linux
    case macOS
    case windows
    case other(String)

    var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .other(let name): return name.isEmpty ? "Unknown" : name
        }
    }
}

/// Source disk formats; the raw value is qemu-img's format name.
enum DiskSourceFormat: String, CaseIterable {
    /// Parallels expanding image ("WithoutFreeSpace" / "WithouFreSpacExt" header).
    case parallels
    /// Plain (preallocated) Parallels image or a raw .img: the bytes are the disk.
    case raw
    /// QEMU / UTM copy-on-write image.
    case qcow2
    /// VMware virtual disk.
    case vmdk
    /// VirtualBox virtual disk.
    case vdi
    /// Hyper-V / Virtual PC disk (.vhd).
    case vpc
    /// Hyper-V disk (.vhdx).
    case vhdx

    var displayName: String {
        switch self {
        case .parallels: return "Parallels expanding image"
        case .raw: return "Raw image"
        case .qcow2: return "QCOW2 (QEMU / UTM)"
        case .vmdk: return "VMDK (VMware)"
        case .vdi: return "VDI (VirtualBox)"
        case .vpc: return "VHD (Hyper-V / Virtual PC)"
        case .vhdx: return "VHDX (Hyper-V)"
        }
    }

    /// Whether converting this format needs qemu-img (raw images are cloned directly).
    var needsQemuImg: Bool { self != .raw }
}

struct ParsedDisk: Identifiable {
    let id = UUID()
    var displayName: String
    /// The .hdd bundle, if the disk came from one.
    var bundleURL: URL?
    /// The data file to convert (.hds or raw .img).
    var imageURL: URL
    var format: DiskSourceFormat
    /// Virtual size in bytes, if known.
    var virtualSize: UInt64?
    var warnings: [String] = []
    /// The disk was captured while the VM was suspended (not cleanly shut down).
    var wasSuspended = false
}

struct ParsedNetworkAdapter: Identifiable {
    let id = UUID()
    var index: Int
    /// Parallels' adapter mode, e.g. "Shared", "Bridged", "Host-only".
    var parallelsMode: String
    /// Normalised "aa:bb:cc:dd:ee:ff" or nil when absent/invalid.
    var macAddress: String?
}

/// Files that make up an Apple Silicon macOS guest's platform identity.
struct MacPlatformFiles {
    var hardwareModel: URL
    var machineIdentifier: URL
    var auxiliaryStorage: URL
}

/// Result of parsing a .pvm bundle, shown in the import summary sheet.
struct ParsedPVM {
    var bundleURL: URL
    var name: String
    var guestOS: ParsedGuestOS
    var guestOSDescription: String
    var architecture: GuestArchitecture
    var architectureEvidence: [String]
    var cpuCount: Int
    var memoryMB: Int
    var disks: [ParsedDisk]
    var networkAdapters: [ParsedNetworkAdapter]
    var isEncrypted: Bool
    /// `nil` when config.pvs does not say.
    var efiEnabled: Bool?
    var macPlatform: MacPlatformFiles?
    var warnings: [String]
    /// What the VM was read from, which changes some wording in the summary.
    var origin: Origin = .parallels

    enum Origin {
        case parallels
        case diskImage
    }

    /// The first valid MAC address from the original configuration.
    var preferredMACAddress: String? {
        networkAdapters.lazy.compactMap(\.macAddress).first
    }

    /// A human-readable reason why this VM cannot be imported, or nil if it can.
    var unsupportedReason: String? {
        if isEncrypted && origin == .diskImage {
            return "This disk image is encrypted. Decrypt it with the tool that created it, then import it again."
        }
        if isEncrypted {
            return "This virtual machine is encrypted. Decrypt it in Parallels Desktop first "
                + "(Configure ▸ Security ▸ uncheck “Encrypt”), then import it again."
        }
        if guestOS == .windows {
            return "Windows VMs from Parallels can't be imported: the installed system depends on "
                + "Parallels' virtual hardware and drivers. Install Windows fresh instead with "
                + "File ▸ New VM from ISO and an ARM64 Windows 11 ISO."
        }
        if architecture == .x86 {
            return "This is an x86 / Intel virtual machine. Virtualization.framework on Apple "
                + "Silicon can only run ARM64 guests, so this VM cannot be converted. "
                + "Reinstall the guest using an ARM64 installer instead."
        }
        if case .other(let name) = guestOS {
            return "Unsupported guest OS “\(name.isEmpty ? "unknown" : name)”. Only ARM64 Linux "
                + "and ARM64 macOS guests can be imported."
        }
        if guestOS == .macOS && macPlatform == nil {
            return "This macOS guest cannot be imported: the bundle does not contain the "
                + "Apple platform files (hardware model, machine identifier and auxiliary storage) "
                + "that Virtualization.framework needs to boot it. macOS VMs created by Parallels "
                + "on Intel Macs, or bundles where these files are missing, cannot be run."
        }
        if disks.isEmpty {
            return "No hard disks were found in this bundle."
        }
        return nil
    }
}
