import Foundation

/// Locates the Homebrew tools the QEMU engine needs: `qemu-system-aarch64` with its UEFI
/// firmware (`brew install qemu`) and `swtpm` for the TPM 2.0 Windows 11 requires
/// (`brew install swtpm`).
struct QEMUTools {
    var qemu: URL
    var firmware: URL
    var swtpm: URL

    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    enum Missing: String, CaseIterable {
        case qemu, swtpm

        var installCommand: String { "brew install \(rawValue)" }
    }

    /// The tools, or the packages still to install.
    static func locate() -> Result<QEMUTools, MissingTools> {
        let qemu = find("qemu-system-aarch64")
        let firmware = qemu.flatMap(firmwareURL)
        let swtpm = find("swtpm")
        var missing: [Missing] = []
        if qemu == nil || firmware == nil { missing.append(.qemu) }
        if swtpm == nil { missing.append(.swtpm) }
        guard let qemu, let firmware, let swtpm else { return .failure(MissingTools(packages: missing)) }
        return .success(QEMUTools(qemu: qemu, firmware: firmware, swtpm: swtpm))
    }

    static var missingPackages: [Missing] {
        if case .failure(let missing) = locate() { return missing.packages }
        return []
    }

    private static func find(_ name: String) -> URL? {
        searchDirectories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `<prefix>/bin/qemu-system-aarch64` → `<prefix>/share/qemu/edk2-aarch64-code.fd`.
    private static func firmwareURL(qemu: URL) -> URL? {
        let url = qemu.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/qemu/edk2-aarch64-code.fd")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct MissingTools: LocalizedError {
    var packages: [QEMUTools.Missing]

    var installCommand: String { "brew install " + packages.map(\.rawValue).joined(separator: " ") }

    var errorDescription: String? {
        "Windows VMs need QEMU and swtpm from Homebrew. Install them in Terminal with “\(installCommand)”, then start the VM again."
    }
}
