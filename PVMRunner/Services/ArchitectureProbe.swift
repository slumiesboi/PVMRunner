import Foundation

/// Inspects a converted raw disk to tell ARM64 guests from x86 ones, for VMs whose
/// config.pvs does not record the architecture. It reads the GPT, then scans the EFI
/// System Partition for the FAT short names of the UEFI boot loaders
/// (BOOTAA64.EFI / GRUBAA64.EFI vs BOOTX64.EFI / GRUBX64.EFI).
enum ArchitectureProbe {
    struct Result {
        var architecture: GuestArchitecture
        var evidence: String
    }

    private static let espType = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    // Discoverable Partitions Specification root partition types.
    private static let rootARM64 = "B921B045-1DF0-41C3-AF44-4C6F280D3FAE"
    private static let rootX86_64 = "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"

    private static let armMarkers = ["BOOTAA64EFI", "GRUBAA64EFI", "SHIMAA64EFI"].map { Data($0.utf8) }
    private static let x86Markers = ["BOOTX64 EFI", "GRUBX64 EFI", "SHIMX64 EFI", "BOOTIA32EFI"].map { Data($0.utf8) }

    private static let maxScanBytes: UInt64 = 512 * 1024 * 1024

    static func probe(rawImage url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Result(architecture: .unknown, evidence: "Disk image could not be read")
        }
        defer { try? handle.close() }

        guard let partitions = readGPT(handle) else {
            // ARM64 guests always boot via UEFI from a GPT disk; MBR-only disks are BIOS/x86.
            if let mbr = read(handle, offset: 510, count: 2), mbr == Data([0x55, 0xAA]) {
                return Result(architecture: .x86, evidence: "Boot disk uses an MBR (BIOS) layout without GPT")
            }
            return Result(architecture: .unknown, evidence: "No partition table found on the boot disk")
        }

        if partitions.contains(where: { $0.type == rootARM64 }) {
            return Result(architecture: .arm64, evidence: "ARM64 root partition type on the boot disk")
        }
        if partitions.contains(where: { $0.type == rootX86_64 }) {
            return Result(architecture: .x86, evidence: "x86-64 root partition type on the boot disk")
        }

        for esp in partitions where esp.type == espType {
            let length = min(esp.length, maxScanBytes)
            switch scan(handle, from: esp.offset, length: length) {
            case .arm64?: return Result(architecture: .arm64, evidence: "ARM64 UEFI boot loader found on the EFI partition")
            case .x86?: return Result(architecture: .x86, evidence: "x86 UEFI boot loader found on the EFI partition")
            default: continue
            }
        }
        return Result(architecture: .unknown, evidence: "No architecture-specific boot loader found")
    }

    // MARK: - Install media

    /// Checks an installer ISO for its UEFI boot loaders. ISO 9660, Rock Ridge and Joliet
    /// directory records name /EFI/BOOT/BOOTAA64.EFI (ARM64) or BOOTX64.EFI (x86); the
    /// records sit near the start of the image and the El Torito EFI image often near the end.
    static func probeInstallMedia(_ url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Result(architecture: .unknown, evidence: "The image could not be read")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let head = min(size, 128 * 1024 * 1024)
        let tailStart = size > head ? max(head, size - 64 * 1024 * 1024) : size

        var foundARM = false, foundX86 = false
        for (start, length) in [(UInt64(0), head), (tailStart, size - tailStart)] where length > 0 {
            var position = start
            while position < start + length {
                let count = Int(min(UInt64(4 * 1024 * 1024 + 64), start + length - position))
                guard let data = read(handle, offset: position, count: count), !data.isEmpty else { break }
                if !foundARM { foundARM = mediaARMMarkers.contains { data.range(of: $0) != nil } }
                if !foundX86 { foundX86 = mediaX86Markers.contains { data.range(of: $0) != nil } }
                position += 4 * 1024 * 1024
            }
        }
        switch (foundARM, foundX86) {
        case (true, _):
            return Result(architecture: .arm64, evidence: "ARM64 UEFI boot loader (BOOTAA64.EFI) found")
        case (false, true):
            return Result(architecture: .x86, evidence: "Only an x86 UEFI boot loader (BOOTX64.EFI) was found")
        default:
            return Result(architecture: .unknown, evidence: "No UEFI boot loader found in the image")
        }
    }

    private static let mediaARMMarkers = markerVariants(["BOOTAA64.EFI", "BOOTAA64EFI"])
    private static let mediaX86Markers = markerVariants(["BOOTX64.EFI", "BOOTX64 EFI", "BOOTIA32.EFI"])

    /// Upper and lower case ASCII (ISO 9660 / Rock Ridge / FAT) plus UCS-2 big-endian (Joliet).
    private static func markerVariants(_ names: [String]) -> [Data] {
        names.flatMap { name -> [Data] in
            [name, name.lowercased()].flatMap { variant -> [Data] in
                let joliet = variant.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
                return [Data(variant.utf8), Data(joliet)]
            }
        }
    }

    private struct Partition {
        var type: String
        var offset: UInt64
        var length: UInt64
    }

    private static func readGPT(_ handle: FileHandle) -> [Partition]? {
        for sectorSize: UInt64 in [512, 4096] {
            guard let header = read(handle, offset: sectorSize, count: 92),
                  header.prefix(8) == Data("EFI PART".utf8) else { continue }
            let entriesLBA = header.uint64(at: 72)
            let count = min(header.uint32(at: 80), 256)
            let entrySize = UInt64(header.uint32(at: 84))
            guard entrySize >= 128,
                  let table = read(handle, offset: entriesLBA * sectorSize, count: Int(UInt64(count) * entrySize)) else {
                return nil
            }
            var partitions: [Partition] = []
            for i in 0..<Int(count) {
                let base = i * Int(entrySize)
                let typeBytes = table.subdata(in: base..<(base + 16))
                guard typeBytes.contains(where: { $0 != 0 }) else { continue }
                let first = table.uint64(at: base + 32), last = table.uint64(at: base + 40)
                guard last >= first else { continue }
                partitions.append(Partition(type: guidString(typeBytes),
                                            offset: first * sectorSize,
                                            length: (last - first + 1) * sectorSize))
            }
            return partitions
        }
        return nil
    }

    private static func scan(_ handle: FileHandle, from offset: UInt64, length: UInt64) -> GuestArchitecture? {
        let chunk = 4 * 1024 * 1024
        let overlap = 16
        var position = offset
        let end = offset + length
        while position < end {
            let count = Int(min(UInt64(chunk + overlap), end - position))
            guard let data = read(handle, offset: position, count: count), !data.isEmpty else { break }
            if armMarkers.contains(where: { data.range(of: $0) != nil }) { return .arm64 }
            if x86Markers.contains(where: { data.range(of: $0) != nil }) { return .x86 }
            position += UInt64(chunk)
        }
        return nil
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    /// GPT GUIDs are mixed-endian: the first three fields are little-endian.
    private static func guidString(_ bytes: Data) -> String {
        let b = [UInt8](bytes)
        let ordered = [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8..<16]
        let hex = ordered.map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)]
            .reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)]
            .reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
