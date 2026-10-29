import XCTest
@testable import PVMRunner

final class PVMParserTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test VM.pvm")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
    }

    private func config(osType: Int = 9, efi: String = "1", mac: String = "001C42A1B2C3",
                        hddEncryption: String = "", vmEncryptionEnabled: String = "0") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ParallelsVirtualMachine schemaVersion="1.0">
          <Identification><VmName>Ubuntu 24.04</VmName></Identification>
          <Settings>
            <General><OsType>\(osType)</OsType></General>
            <Startup><Bios><EfiEnabled>\(efi)</EfiEnabled></Bios></Startup>
            <VmEncryptionInfo>
              <Enabled>\(vmEncryptionEnabled)</Enabled>
              <SecretKeySourceType>1</SecretKeySourceType>
              <SecretKeyId></SecretKeyId>
            </VmEncryptionInfo>
          </Settings>
          <Hardware>
            <Cpu><Number>4</Number></Cpu>
            <Memory><RAM>4096</RAM></Memory>
            <Hdd id="0">
              <Enabled>1</Enabled>
              <EmulatedType>1</EmulatedType>
              <SystemName>/Users/someone/Parallels/Old.pvm/harddisk.hdd</SystemName>
              <Size>65536</Size>
              <Encryption><Engine>\(hddEncryption)</Engine></Encryption>
            </Hdd>
            <NetworkAdapter id="0">
              <Enabled>1</Enabled>
              <EmulatedType>1</EmulatedType>
              <MAC>\(mac)</MAC>
            </NetworkAdapter>
          </Hardware>
        </ParallelsVirtualMachine>
        """
    }

    private func makeHDD(snapshot: Bool = false) throws {
        let hdd = bundleURL.appendingPathComponent("harddisk.hdd")
        try FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)
        let base = "{5fbaabe3-6958-40ff-92a7-860e329aab41}"
        let delta = "{11111111-2222-3333-4444-555555555555}"
        var images = "<Image><GUID>\(base)</GUID><Type>Compressed</Type><File>harddisk.hdd.0.\(base).hds</File></Image>"
        var shots = "<Shot><GUID>\(base)</GUID><ParentGUID>{00000000-0000-0000-0000-000000000000}</ParentGUID></Shot>"
        if snapshot {
            images += "<Image><GUID>\(delta)</GUID><Type>Compressed</Type><File>harddisk.hdd.0.\(delta).hds</File></Image>"
            shots += "<Shot><GUID>\(delta)</GUID><ParentGUID>\(base)</ParentGUID></Shot>"
        }
        let descriptor = """
        <Parallels_disk_image Version="1.0">
          <Disk_Parameters><Disk_size>134217728</Disk_size>
            <Encryption><Engine>{00000000-0000-0000-0000-000000000000}</Engine><Data></Data></Encryption>
          </Disk_Parameters>
          <StorageData><Storage><Start>0</Start><End>134217728</End>\(images)</Storage></StorageData>
          <Snapshots>\(shots)</Snapshots>
        </Parallels_disk_image>
        """
        try descriptor.write(to: hdd.appendingPathComponent("DiskDescriptor.xml"), atomically: true, encoding: .utf8)
        var header = Data("WithouFreSpacExt".utf8)
        header.append(Data(count: 496))
        try header.write(to: hdd.appendingPathComponent("harddisk.hdd.0.\(base).hds"))
        if snapshot { try header.write(to: hdd.appendingPathComponent("harddisk.hdd.0.\(delta).hds")) }
    }

    private func parse(_ xml: String) throws -> ParsedPVM {
        try PVMParser().parse(configData: Data(xml.utf8), bundleURL: bundleURL)
    }

    func testParsesLinuxVM() throws {
        try makeHDD()
        let parsed = try parse(config())
        XCTAssertEqual(parsed.name, "Ubuntu 24.04")
        XCTAssertEqual(parsed.guestOS, .linux)
        XCTAssertEqual(parsed.guestOSDescription, "Ubuntu")
        XCTAssertEqual(parsed.cpuCount, 4)
        XCTAssertEqual(parsed.memoryMB, 4096)
        XCTAssertEqual(parsed.disks.count, 1)
        XCTAssertEqual(parsed.disks.first?.format, .parallels)
        XCTAssertEqual(parsed.disks.first?.virtualSize, 134_217_728 * 512)
        XCTAssertEqual(parsed.preferredMACAddress, "00:1c:42:a1:b2:c3")
        XCTAssertFalse(parsed.isEncrypted)
        XCTAssertNil(parsed.unsupportedReason)
    }

    func testRejectsWindows() throws {
        try makeHDD()
        XCTAssertNotNil(try parse(config(osType: 8)).unsupportedReason)
    }

    func testRejectsLegacyBIOSAsX86() throws {
        try makeHDD()
        let parsed = try parse(config(efi: "0"))
        XCTAssertEqual(parsed.architecture, .x86)
        XCTAssertNotNil(parsed.unsupportedReason)
    }

    func testRejectsEncryptedDisk() throws {
        try makeHDD()
        let parsed = try parse(config(hddEncryption: "{a1b2c3d4-0000-0000-0000-000000000001}"))
        XCTAssertTrue(parsed.isEncrypted)
        XCTAssertNotNil(parsed.unsupportedReason)
    }

    /// Real Parallels configs carry `VmEncryptionInfo` with a non-zero key source type even
    /// when encryption is off; only `Enabled` decides.
    func testDisabledVMEncryptionInfoIsNotEncrypted() throws {
        try makeHDD()
        XCTAssertFalse(try parse(config()).isEncrypted)
        XCTAssertTrue(try parse(config(vmEncryptionEnabled: "1")).isEncrypted)
    }

    func testRejectsMacOSWithoutPlatformFiles() throws {
        try makeHDD()
        XCTAssertNotNil(try parse(config(osType: 7)).unsupportedReason)
    }

    func testSnapshotChainUsesBaseImage() throws {
        try makeHDD(snapshot: true)
        let disk = try XCTUnwrap(try parse(config()).disks.first)
        XCTAssertTrue(disk.imageURL.lastPathComponent.contains("5fbaabe3"))
        XCTAssertFalse(disk.warnings.isEmpty)
    }

    func testMACNormalization() {
        XCTAssertEqual(MACAddress.normalize("001C42A1B2C3"), "00:1c:42:a1:b2:c3")
        XCTAssertEqual(MACAddress.normalize("00-1C-42-A1-B2-C3"), "00:1c:42:a1:b2:c3")
        XCTAssertNil(MACAddress.normalize("000000000000"))
        XCTAssertNil(MACAddress.normalize("011C42A1B2C3"), "multicast addresses are invalid")
        XCTAssertNil(MACAddress.normalize("001C42A1B2"))
    }

    func testProgressParsing() {
        XCTAssertEqual(DiskConverter.lastProgressValue(in: "    (0.00/100%)\r    (42.50/100%)\r"), 42.5)
        XCTAssertNil(DiskConverter.lastProgressValue(in: "nothing"))
    }

    /// End-to-end conversion with the real qemu-img, skipped when it is not installed.
    func testConvertsParallelsImage() async throws {
        guard let qemuImg = DiskConverter.locateQemuImg() else { throw XCTSkip("qemu-img not installed") }
        let source = bundleURL.appendingPathComponent("test.hds")
        let create = Process()
        create.executableURL = qemuImg
        create.arguments = ["create", "-q", "-f", "parallels", source.path, "64M"]
        try create.run()
        create.waitUntilExit()
        XCTAssertEqual(PVMParser.detectFormat(of: source), .parallels)

        let destination = bundleURL.appendingPathComponent("disk0.img")
        try await DiskConverter().convert(source: source, format: .parallels, to: destination) { _ in }
        XCTAssertEqual(try fileSize(destination), 64 * 1024 * 1024)

        try await DiskConverter().resize(image: destination, to: 128 * 1024 * 1024)
        XCTAssertEqual(try fileSize(destination), 128 * 1024 * 1024)
        XCTAssertEqual(ArchitectureProbe.probe(rawImage: destination).architecture, .unknown)
    }

    /// Reads the size from disk; URL resource values are cached per URL instance.
    private func fileSize(_ url: URL) throws -> UInt64 {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
    }
}
