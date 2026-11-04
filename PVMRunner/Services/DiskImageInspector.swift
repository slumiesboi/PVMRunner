import Foundation

enum DiskImageInspectorError: LocalizedError {
    case unsupportedFormat(String, file: String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format, let file):
            return "“\(file)” is a \(format) image, which PVMRunner cannot import. Supported formats are "
                + "QCOW2, VMDK, VDI, VHD, VHDX, Parallels and raw images."
        case .unreadable(let detail):
            return "The disk image could not be read: \(detail)"
        }
    }
}

/// Turns a standalone disk image from another hypervisor (UTM/QEMU, VMware, VirtualBox,
/// Hyper-V, or a raw image) into a `ParsedPVM`, so it goes through the same summary sheet,
/// conversion and architecture check as a Parallels import.
struct DiskImageInspector {
    /// Extensions offered in the open panel and accepted by drag and drop.
    static let fileExtensions = ["qcow2", "qcow", "vmdk", "vdi", "vhd", "vhdx", "img", "raw", "hds"]

    static func isDiskImage(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    func inspect(_ url: URL) throws -> ParsedPVM {
        let fileName = url.lastPathComponent
        var warnings = [
            "A disk image carries no VM settings, so CPU, memory and network use defaults. Adjust them below.",
            "The image must be an ARM64 guest that boots with UEFI (most ARM64 Linux cloud and UTM images do).",
        ]
        var format = Self.formatFromExtension(url)
        var virtualSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) }
        var encrypted = false

        if let info = try Self.qemuInfo(url) {
            guard let detected = info["format"] as? String else {
                throw DiskImageInspectorError.unreadable("qemu-img did not report a format")
            }
            guard let known = DiskSourceFormat(rawValue: detected) else {
                throw DiskImageInspectorError.unsupportedFormat(detected.uppercased(), file: fileName)
            }
            format = known
            if let size = info["virtual-size"] as? NSNumber { virtualSize = size.uint64Value }
            encrypted = (info["encrypted"] as? Bool) == true
            if let backing = info["backing-filename"] as? String {
                warnings.append("This image is based on “\((backing as NSString).lastPathComponent)”. The conversion "
                    + "merges the backing chain into one standalone disk.")
            }
        } else if format.needsQemuImg {
            warnings.append("qemu-img is not installed, so the format was guessed from the file extension.")
        }

        let name = url.deletingPathExtension().lastPathComponent
        let hint = name.lowercased()
        let distro = PVMParser.linuxDistroNames.first(where: hint.contains)?.capitalized

        return ParsedPVM(
            bundleURL: url, name: name, guestOS: .linux, guestOSDescription: distro ?? "Linux",
            architecture: .unknown,
            architectureEvidence: ["Checked from the disk's EFI boot loader after conversion"],
            cpuCount: 2, memoryMB: 4096,
            disks: [ParsedDisk(displayName: fileName, bundleURL: nil, imageURL: url, format: format,
                               virtualSize: virtualSize)],
            networkAdapters: [], isEncrypted: encrypted, efiEnabled: nil, macPlatform: nil,
            warnings: warnings, origin: .diskImage)
    }

    static func formatFromExtension(_ url: URL) -> DiskSourceFormat {
        switch url.pathExtension.lowercased() {
        case "qcow2", "qcow": return .qcow2
        case "vmdk": return .vmdk
        case "vdi": return .vdi
        case "vhd": return .vpc
        case "vhdx": return .vhdx
        case "hds": return PVMParser.detectFormat(of: url)
        default: return .raw
        }
    }

    /// `qemu-img info --output=json`, or nil when qemu-img is not installed.
    static func qemuInfo(_ url: URL) throws -> [String: Any]? {
        guard let qemuImg = DiskConverter.locateQemuImg() else { return nil }
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["info", "--output=json", url.path]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiskImageInspectorError.unreadable(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiskImageInspectorError.unreadable("unexpected qemu-img output")
        }
        return json
    }
}
