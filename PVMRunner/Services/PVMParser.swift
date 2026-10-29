import Foundation

enum PVMParserError: LocalizedError {
    case notABundle(URL)
    case missingConfig(URL)
    case unreadableConfig(String)

    var errorDescription: String? {
        switch self {
        case .notABundle(let url):
            return "“\(url.lastPathComponent)” is not a Parallels virtual machine (.pvm) bundle."
        case .missingConfig(let url):
            return "“\(url.lastPathComponent)” does not contain a config.pvs file, so it cannot be read as a Parallels VM."
        case .unreadableConfig(let detail):
            return "config.pvs could not be read as XML. If this VM is encrypted, decrypt it in Parallels Desktop first. (\(detail))"
        }
    }
}

/// Reads a Parallels Desktop `.pvm` bundle (a directory package containing `config.pvs`
/// and one or more `.hdd` disk bundles). The original bundle is only ever read.
struct PVMParser {
    private let fileManager = FileManager.default

    /// Parallels `OsType` values (PVS_GUEST_TYPE_* in the Parallels SDK).
    private static let parallelsOSTypes: [Int: ParsedGuestOS] = [
        7: .macOS, 8: .windows, 9: .linux,
        10: .other("FreeBSD"), 11: .other("OS/2"), 12: .other("MS-DOS"), 13: .other("NetWare"),
        14: .other("Solaris"), 15: .other("Chrome OS"), 16: .other("Android"),
    ]

    private static let zeroGUID = "{00000000-0000-0000-0000-000000000000}"

    func parse(bundleURL: URL) throws -> ParsedPVM {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PVMParserError.notABundle(bundleURL)
        }
        let configURL = bundleURL.appendingPathComponent("config.pvs")
        guard fileManager.fileExists(atPath: configURL.path) else {
            // Parallels stores Apple Silicon macOS guests as .macvm bundles without config.pvs.
            if let platform = findMacPlatformFiles(in: bundleURL) {
                return parseMacVMBundle(bundleURL: bundleURL, platform: platform)
            }
            throw PVMParserError.missingConfig(bundleURL)
        }
        let data = try Data(contentsOf: configURL)
        return try parse(configData: data, bundleURL: bundleURL)
    }

    func parse(configData: Data, bundleURL: URL) throws -> ParsedPVM {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: configData, options: [])
        } catch {
            throw PVMParserError.unreadableConfig(error.localizedDescription)
        }
        guard let root = document.rootElement() else {
            throw PVMParserError.unreadableConfig("empty document")
        }

        var warnings: [String] = []
        var blocking: [String] = []

        let name = root.firstText("Identification/VmName")
            ?? bundleURL.deletingPathExtension().lastPathComponent

        // Guest OS
        let osTypeValue = root.firstText("Settings/General/OsType").flatMap(Int.init)
            ?? root.firstDescendantText(named: "OsType").flatMap(Int.init)
        var guestOS = osTypeValue.flatMap { Self.parallelsOSTypes[$0] } ?? .other("")
        let nameHint = name.lowercased()
        if case .other(let label) = guestOS, label.isEmpty {
            // Fall back to the VM name when the type is missing or unknown.
            if nameHint.contains("windows") || nameHint.contains("win11") || nameHint.contains("win10") {
                guestOS = .windows
            } else if nameHint.contains("macos") || nameHint.contains("mac os") {
                guestOS = .macOS
            } else if Self.linuxDistroNames.contains(where: nameHint.contains) || nameHint.contains("linux") {
                guestOS = .linux
            }
        }
        // Hardware
        let cpuCount = max(1, root.firstText("Hardware/Cpu/Number").flatMap(Int.init) ?? 2)
        let memoryMB = max(512, root.firstText("Hardware/Memory/RAM").flatMap(Int.init) ?? 2048)
        let efiEnabled = root.firstText("Settings/Startup/Bios/EfiEnabled").map { $0 != "0" }

        // Encryption: any *Encrypt* element carrying a real value means the VM or a disk is encrypted.
        var isEncrypted = Self.containsEncryptionMarker(root)

        // Disks
        var disks: [ParsedDisk] = []
        for hdd in root.elements(at: "Hardware/Hdd") {
            if hdd.firstText("Enabled") == "0" { continue }
            if hdd.firstText("EmulatedType") == "0" {
                warnings.append("Skipped a disk that maps a physical device (\(hdd.firstText("SystemName") ?? "?")).")
                continue
            }
            guard let systemName = hdd.firstText("SystemName"), !systemName.isEmpty else { continue }
            guard let hddURL = resolveDiskPath(systemName, bundleURL: bundleURL) else {
                warnings.append("Disk “\((systemName as NSString).lastPathComponent)” was not found inside the bundle and was skipped.")
                continue
            }
            let sizeMB = hdd.firstText("Size").flatMap(UInt64.init)
            do {
                let result = try parseHDDBundle(hddURL, fallbackSize: sizeMB.map { $0 * 1024 * 1024 })
                if result.encrypted { isEncrypted = true }
                blocking.append(contentsOf: result.blocking)
                if let disk = result.disk { disks.append(disk) }
            } catch {
                warnings.append("Could not read disk “\(hddURL.lastPathComponent)”: \(error.localizedDescription)")
            }
        }

        // The VM name is often custom ("Fleet"); Parallels names the disk after the distro.
        let descriptionHint = ([nameHint] + disks.map { $0.displayName.lowercased() }).joined(separator: " ")
        let guestOSDescription = Self.linuxDistroNames.first(where: descriptionHint.contains)?.capitalized
            ?? guestOS.displayName

        // A suspended VM's RAM lives in a .mem file that cannot be carried over, so the disk is
        // in the state of a sudden power loss.
        let bundleFiles = (try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path)) ?? []
        if disks.contains(where: \.wasSuspended)
            || bundleFiles.contains(where: { $0.hasSuffix(".mem") || $0 == "config.sav" }) {
            warnings.insert("This VM is suspended in Parallels. Its memory state cannot be imported, so the guest "
                + "will boot as if the power was cut and may lose unsaved work or need a filesystem check. "
                + "For a clean import, resume it in Parallels and shut it down first.", at: 0)
        }

        // Network adapters
        var adapters: [ParsedNetworkAdapter] = []
        for (offset, adapter) in root.elements(at: "Hardware/NetworkAdapter").enumerated() {
            if adapter.firstText("Enabled") == "0" { continue }
            let mode: String
            switch adapter.firstText("EmulatedType") {
            case "0": mode = "Host-only"
            case "1": mode = "Shared"
            case "2": mode = "Bridged"
            default: mode = "Unknown"
            }
            adapters.append(ParsedNetworkAdapter(
                index: adapter.firstText("Index").flatMap(Int.init) ?? offset,
                parallelsMode: mode,
                macAddress: adapter.firstText("MAC").flatMap(MACAddress.normalize)))
        }

        if adapters.contains(where: { $0.parallelsMode == "Bridged" }) {
            warnings.append("This VM used Bridged networking in Parallels. If the guest has a static IP address "
                + "for your local network, it will not connect under NAT: switch the guest's connection to "
                + "DHCP (Automatic), or use Bridged mode once the app has the networking entitlement.")
        }

        // Architecture
        var evidence: [String] = []
        var architecture = GuestArchitecture.unknown
        let macPlatform = guestOS == .macOS ? findMacPlatformFiles(in: bundleURL) : nil
        let configText = (String(data: configData, encoding: .utf8) ?? "").lowercased()
        if macPlatform != nil {
            architecture = .arm64
            evidence.append("Apple Silicon platform files present")
        } else if efiEnabled == false {
            architecture = .x86
            evidence.append("Legacy BIOS boot (EFI disabled); ARM64 guests always boot via UEFI")
        } else if ["x86_64", "amd64", "i386", "i686"].contains(where: configText.contains) {
            architecture = .x86
            evidence.append("config.pvs references an x86 architecture")
        } else if ["aarch64", "arm64"].contains(where: configText.contains) {
            architecture = .arm64
            evidence.append("config.pvs references ARM64")
        } else {
            evidence.append("Not recorded in config.pvs; the boot disk is checked after conversion")
        }

        var parsed = ParsedPVM(
            bundleURL: bundleURL, name: name, guestOS: guestOS, guestOSDescription: guestOSDescription,
            architecture: architecture, architectureEvidence: evidence,
            cpuCount: cpuCount, memoryMB: memoryMB, disks: disks, networkAdapters: adapters,
            isEncrypted: isEncrypted, efiEnabled: efiEnabled, macPlatform: macPlatform, warnings: warnings)
        if let firstBlocking = blocking.first, parsed.unsupportedReason == nil {
            parsed.warnings.insert(firstBlocking, at: 0)
            parsed.disks = []
        }
        return parsed
    }

    // MARK: - .hdd bundles

    private struct HDDResult {
        var disk: ParsedDisk?
        var encrypted = false
        var blocking: [String] = []
    }

    private func parseHDDBundle(_ url: URL, fallbackSize: UInt64?) throws -> HDDResult {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            // A bare image file (some exports reference .hds/.img files directly).
            return HDDResult(disk: ParsedDisk(
                displayName: url.lastPathComponent, bundleURL: nil, imageURL: url,
                format: Self.detectFormat(of: url), virtualSize: fallbackSize ?? fileSize(url)))
        }

        var result = HDDResult()
        var warnings: [String] = []
        var imageURL: URL?
        var virtualSize = fallbackSize
        var wasSuspended = false

        let descriptorURL = url.appendingPathComponent("DiskDescriptor.xml")
        if let data = try? Data(contentsOf: descriptorURL),
           let doc = try? XMLDocument(data: data, options: []),
           let root = doc.rootElement() {
            if let sectors = root.firstText("Disk_Parameters/Disk_size").flatMap(UInt64.init) {
                virtualSize = sectors * 512
            }
            if Self.containsEncryptionMarker(root) { result.encrypted = true }
            wasSuspended = root.firstText("Disk_Parameters/Miscellaneous/SuspendState") == "1"

            let storages = root.elements(at: "StorageData/Storage")
            if storages.count > 1 {
                result.blocking.append("Disk “\(url.lastPathComponent)” is split into \(storages.count) pieces. "
                    + "Convert it to a single file in Parallels Desktop (Hardware ▸ Hard Disk ▸ Edit) and try again.")
            }
            let images = storages.first?.elements(at: "Image") ?? []
            var filesByGUID: [String: String] = [:]
            for image in images {
                if let guid = image.firstText("GUID"), let file = image.firstText("File") {
                    filesByGUID[guid.lowercased()] = file
                }
            }
            if images.count > 1 {
                // Snapshot chain: the base image has the all-zero parent GUID.
                let baseGUID = root.elements(at: "Snapshots/Shot")
                    .first { $0.firstText("ParentGUID") == Self.zeroGUID }?
                    .firstText("GUID")?.lowercased()
                if let baseGUID, let file = filesByGUID[baseGUID] {
                    imageURL = url.appendingPathComponent(file)
                }
                warnings.append("This disk has \(images.count - 1) snapshot(s). Only the base image is imported, "
                    + "so changes made after the first snapshot are missing. Delete all snapshots in "
                    + "Parallels Desktop first to merge them.")
            } else if let file = images.first?.firstText("File") {
                imageURL = url.appendingPathComponent(file)
            }
        }

        if imageURL == nil {
            // No usable descriptor: take the largest .hds file in the bundle.
            let candidates = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter { $0.pathExtension.lowercased() == "hds" } ?? []
            imageURL = candidates.max { (fileSize($0) ?? 0) < (fileSize($1) ?? 0) }
        }
        guard let imageURL, fileManager.fileExists(atPath: imageURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no .hds image file found"])
        }

        result.disk = ParsedDisk(
            displayName: url.deletingPathExtension().lastPathComponent, bundleURL: url, imageURL: imageURL,
            format: Self.detectFormat(of: imageURL), virtualSize: virtualSize, warnings: warnings,
            wasSuspended: wasSuspended)
        return result
    }

    /// Expanding Parallels images start with a 16-byte magic; plain images are raw bytes.
    static func detectFormat(of url: URL) -> DiskSourceFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .parallels }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 16)).flatMap { String(data: $0, encoding: .ascii) }
        return (magic == "WithoutFreeSpace" || magic == "WithouFreSpacExt") ? .parallels : .raw
    }

    /// config.pvs stores either an absolute path (from the original host) or a bundle-relative one.
    private func resolveDiskPath(_ systemName: String, bundleURL: URL) -> URL? {
        let candidates = [
            bundleURL.appendingPathComponent(systemName),
            bundleURL.appendingPathComponent((systemName as NSString).lastPathComponent),
            URL(fileURLWithPath: systemName),
        ]
        // Prefer copies inside the bundle: an absolute path may point at a stale original location.
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func fileSize(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(UInt64.init) }
    }

    // MARK: - macOS guests

    /// Looks for the hardware model, machine identifier and auxiliary storage that an
    /// Apple Silicon macOS guest needs. Parallels keeps them in a .macvm bundle.
    func findMacPlatformFiles(in bundleURL: URL) -> MacPlatformFiles? {
        guard let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        var hardware: URL?, machine: URL?, auxiliary: URL?
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let key = url.deletingPathExtension().lastPathComponent.lowercased()
                .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            if key.contains("hardwaremodel") { hardware = hardware ?? url }
            else if key.contains("machineidentifier") { machine = machine ?? url }
            else if key.contains("auxiliarystorage") || key == "auxiliary" { auxiliary = auxiliary ?? url }
        }
        guard let hardware, let machine, let auxiliary else { return nil }
        return MacPlatformFiles(hardwareModel: hardware, machineIdentifier: machine, auxiliaryStorage: auxiliary)
    }

    private func parseMacVMBundle(bundleURL: URL, platform: MacPlatformFiles) -> ParsedPVM {
        let images = (fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { ["img", "raw", "hds"].contains($0.pathExtension.lowercased()) }
            .filter { $0.standardizedFileURL != platform.auxiliaryStorage.standardizedFileURL }
            .sorted { (fileSize($0) ?? 0) > (fileSize($1) ?? 0) }
        let disks = images.prefix(1).map {
            ParsedDisk(displayName: $0.lastPathComponent, bundleURL: nil, imageURL: $0,
                       format: Self.detectFormat(of: $0), virtualSize: fileSize($0))
        }
        return ParsedPVM(
            bundleURL: bundleURL, name: bundleURL.deletingPathExtension().lastPathComponent,
            guestOS: .macOS, guestOSDescription: "macOS", architecture: .arm64,
            architectureEvidence: ["Apple Silicon platform files present"],
            cpuCount: 4, memoryMB: 8192, disks: Array(disks), networkAdapters: [],
            isEncrypted: false, efiEnabled: nil, macPlatform: platform,
            warnings: ["No config.pvs was found; CPU and memory are defaults, adjust them below."])
    }

    // MARK: - Helpers

    private static let linuxDistroNames = [
        "ubuntu", "debian", "fedora", "kali", "centos", "rocky", "alma", "red hat", "rhel",
        "opensuse", "suse", "arch", "manjaro", "mint", "alpine", "gentoo", "nixos", "elementary",
    ]

    /// Parallels writes encryption blocks even for unencrypted VMs, e.g.
    /// `<VmEncryptionInfo><Enabled>0</Enabled><SecretKeySourceType>1</SecretKeySourceType>…`
    /// on the VM and `<Encryption><Engine>{0000…}</Engine>…` on disks, so only the
    /// fields that actually switch encryption on are checked.
    static func containsEncryptionMarker(_ element: XMLElement) -> Bool {
        var stack: [XMLElement] = [element]
        while let current = stack.popLast() {
            if let name = current.name, name.lowercased().contains("encrypt"), isEncryptionActive(current) {
                return true
            }
            stack.append(contentsOf: current.children?.compactMap { $0 as? XMLElement } ?? [])
        }
        return false
    }

    private static func isEncryptionActive(_ element: XMLElement) -> Bool {
        func isSet(_ value: String?) -> Bool {
            guard let value = value?.lowercased() else { return false }
            return !["", "0", "false", zeroGUID].contains(value)
        }
        let children = element.children?.compactMap { $0 as? XMLElement } ?? []
        if children.isEmpty {
            return isSet(element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let enabled = element.firstText("Enabled") { return isSet(enabled) }
        if let engine = element.firstText("Engine") { return isSet(engine) }
        // No switch field: treat stored key material as a sign of encryption.
        let keyFields = ["Data", "KeyChecker", "SecretKeyId", "PluginId", "Hash1"]
        return keyFields.contains { isSet(element.firstText($0)) }
    }
}

enum MACAddress {
    /// Accepts "001C42AABBCC", "00:1c:42:aa:bb:cc" or "00-1C-42-AA-BB-CC" and returns
    /// "00:1c:42:aa:bb:cc", or nil if the address is malformed, multicast or all zeros.
    static func normalize(_ raw: String) -> String? {
        let hex = raw.lowercased().filter { $0.isHexDigit }
        guard hex.count == 12, raw.count == 12 || raw.count == 17 else { return nil }
        let bytes = stride(from: 0, to: 12, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }
        guard let first = UInt8(bytes[0], radix: 16), first & 0x01 == 0 else { return nil }
        guard bytes.contains(where: { $0 != "00" }) else { return nil }
        return bytes.joined(separator: ":")
    }
}

extension XMLElement {
    func elements(at path: String) -> [XMLElement] {
        (try? nodes(forXPath: path))?.compactMap { $0 as? XMLElement } ?? []
    }

    func firstText(_ path: String) -> String? {
        elements(at: path).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstDescendantText(named name: String) -> String? {
        firstText(".//\(name)")
    }
}
