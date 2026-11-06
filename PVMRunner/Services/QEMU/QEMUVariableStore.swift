import Foundation

/// Writes a fresh UEFI variable store for QEMU's ARM firmware (edk2 ArmVirtQemu) with the
/// display resolution preset. The firmware's ramfb screen starts at 800 × 600 and Windows
/// keeps whatever mode the firmware chose, so presetting 1024 × 768 (ramfb's largest mode)
/// gives Windows a usable screen before any display driver is installed. It's the same
/// setting as Device Manager ▸ OVMF Platform Configuration in the firmware menu.
///
/// The layout is edk2's: a firmware volume header and authenticated variable store, one
/// `PlatformConfig` variable, the fault-tolerant-write working block at 256 KB, and the
/// rest of the 64 MB flash. If a future firmware build disagrees with this layout, it
/// simply reformats the store and starts at 800 × 600.
enum QEMUVariableStore {
    static let flashSize = 64 * 1024 * 1024
    static let resolution = (width: UInt32(1024), height: UInt32(768))

    static func create(at url: URL) throws {
        var data = Data(repeating: 0xFF, count: 0xC0000)
        data.append(Data(count: flashSize - 0xC0000))
        data.replaceSubrange(0..<storeHeader.count, with: storeHeader)
        data.replaceSubrange(0x40000..<0x40000 + ftwHeader.count, with: ftwHeader)
        let variable = platformConfig(width: resolution.width, height: resolution.height)
        data.replaceSubrange(storeHeader.count..<storeHeader.count + variable.count, with: variable)
        try data.write(to: url)
    }

    /// `PlatformConfig` (OvmfPkg PlatformDxe): horizontal and vertical resolution, NV + BS.
    static func platformConfig(width: UInt32, height: UInt32) -> Data {
        let name = Data("PlatformConfig\0".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        var payload = Data()
        payload.appendLE(width)
        payload.appendLE(height)

        var record = Data([0xAA, 0x55, 0x3F, 0x00])  // StartId, State = added, reserved
        record.appendLE(UInt32(0x3))                  // non-volatile | boot service access
        record.append(Data(count: 8 + 16 + 4))        // monotonic count, timestamp, public key index
        record.appendLE(UInt32(name.count))
        record.appendLE(UInt32(payload.count))
        record.append(contentsOf: [0x1C, 0xC5, 0x35, 0x72, 0x80, 0x0C, 0xAB, 0x4C,  // 7235c51c-0c80-4cab-
                                   0x87, 0xAC, 0x3B, 0x08, 0x4A, 0x63, 0x04, 0xB1]) // 87ac-3b084a6304b1
        record.append(name)
        record.append(payload)
        return record
    }

    /// Firmware volume header for the 768 KB variable volume (as built in Homebrew's
    /// edk2-aarch64), followed by the authenticated variable store header.
    private static let storeHeader = Data([
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x8D, 0x2B, 0xF1, 0xFF, 0x96, 0x76, 0x8B, 0x4C, 0xA9, 0x85, 0x27, 0x47, 0x07, 0x5B, 0x4F, 0x50,
        0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5F, 0x46, 0x56, 0x48, 0x36, 0x0E, 0x00, 0x00,
        0x48, 0x00, 0xF8, 0xF8, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x2C, 0xF3, 0xAA, 0x7B, 0x94, 0x9A, 0x43,
        0xA1, 0x80, 0x2E, 0x14, 0x4E, 0xC3, 0x77, 0x92, 0xB8, 0xFF, 0x03, 0x00, 0x5A, 0xFE, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    /// Fault-tolerant-write working block header (signature, CRC, valid flags, size).
    private static let ftwHeader = Data([
        0x2B, 0x29, 0x58, 0x9E, 0x68, 0x7C, 0x7D, 0x49, 0xA0, 0xCE, 0x65, 0x00, 0xFD, 0x9F, 0x1B, 0x95,
        0x5B, 0xE7, 0xC6, 0x86, 0xFE, 0xFF, 0xFF, 0xFF, 0xE0, 0xFF, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
