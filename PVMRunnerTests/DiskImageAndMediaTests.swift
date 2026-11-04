import Virtualization
import XCTest
@testable import PVMRunner

/// Imports images in each supported format, probes installer ISOs, and hot-swaps an ISO
/// on a running VM. Images are created locally with qemu-img and hdiutil.
@MainActor
final class DiskImageAndMediaTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func qemuImg() throws -> String {
        guard let url = DiskConverter.locateQemuImg() else { throw XCTSkip("qemu-img not installed") }
        return url.path
    }

    // MARK: Disk images

    func testInspectsAndConvertsEveryFormat() async throws {
        let qemu = try qemuImg()
        let size: UInt64 = 64 * 1024 * 1024
        let cases: [(DiskSourceFormat, String)] = [(.qcow2, "qcow2"), (.vmdk, "vmdk"), (.vdi, "vdi"),
                                                    (.vpc, "vhd"), (.vhdx, "vhdx")]
        for (format, ext) in cases {
            let image = directory.appendingPathComponent("guest.\(ext)")
            var arguments = ["create", "-q", "-f", format.rawValue]
            if format == .vpc { arguments += ["-o", "force_size=on"] }
            XCTAssertEqual(try run(qemu, arguments + [image.path, "64M"]), 0, "create \(ext)")

            let parsed = try DiskImageInspector().inspect(image)
            XCTAssertEqual(parsed.origin, .diskImage)
            XCTAssertEqual(parsed.disks.first?.format, format, ext)
            XCTAssertEqual(parsed.disks.first?.virtualSize, size, ext)
            XCTAssertNil(parsed.unsupportedReason, ext)

            let raw = directory.appendingPathComponent("\(ext).img")
            try await DiskConverter().convert(source: image, format: format, to: raw) { _ in }
            let attributes = try FileManager.default.attributesOfItem(atPath: raw.path)
            XCTAssertEqual(attributes[.size] as? UInt64, size, "converted \(ext)")
        }
    }

    func testDetectsRealFormatDespiteExtension() throws {
        let qemu = try qemuImg()
        let image = directory.appendingPathComponent("actually-qcow2.img")
        XCTAssertEqual(try run(qemu, ["create", "-q", "-f", "qcow2", image.path, "16M"]), 0)
        XCTAssertEqual(try DiskImageInspector().inspect(image).disks.first?.format, .qcow2)
    }

    func testRejectsUnsupportedFormat() throws {
        let qemu = try qemuImg()
        let image = directory.appendingPathComponent("disk.qcow2")
        XCTAssertEqual(try run(qemu, ["create", "-q", "-f", "qed", image.path, "16M"]), 0)
        XCTAssertThrowsError(try DiskImageInspector().inspect(image))
    }

    func testRejectsEncryptedImage() throws {
        let qemu = try qemuImg()
        let image = directory.appendingPathComponent("secret.qcow2")
        XCTAssertEqual(try run(qemu, ["create", "-q", "--object", "secret,id=sec0,data=test-passphrase",
                                      "-f", "qcow2", "-o", "encrypt.format=luks,encrypt.key-secret=sec0",
                                      image.path, "16M"]), 0)
        let parsed = try DiskImageInspector().inspect(image)
        XCTAssertTrue(parsed.isEncrypted)
        XCTAssertNotNil(parsed.unsupportedReason)
    }

    func testImportableExtensions() {
        for name in ["a.pvm", "a.qcow2", "a.vmdk", "a.vdi", "a.vhd", "a.vhdx", "a.img", "a.raw"] {
            XCTAssertTrue(ImportViewModel.isImportable(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        XCTAssertFalse(ImportViewModel.isImportable(URL(fileURLWithPath: "/tmp/a.iso")))
    }

    // MARK: Install media

    /// Builds an ISO 9660 + Joliet image whose /EFI/BOOT holds the given loaders.
    private func makeISO(_ name: String, loaders: [String]) throws -> URL {
        let root = directory.appendingPathComponent("\(name)-root")
        let boot = root.appendingPathComponent("EFI/BOOT")
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: root.appendingPathComponent("README.TXT"))
        for loader in loaders {
            try Data(count: 4096).write(to: boot.appendingPathComponent(loader))
        }
        let iso = directory.appendingPathComponent("\(name).iso")
        XCTAssertEqual(try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet",
                                                    "-o", iso.path, root.path]), 0)
        return iso
    }

    func testInstallMediaProbe() throws {
        XCTAssertEqual(ArchitectureProbe.probeInstallMedia(try makeISO("arm", loaders: ["BOOTAA64.EFI"])).architecture, .arm64)
        XCTAssertEqual(ArchitectureProbe.probeInstallMedia(try makeISO("x86", loaders: ["BOOTX64.EFI"])).architecture, .x86)
        XCTAssertEqual(ArchitectureProbe.probeInstallMedia(try makeISO("both", loaders: ["BOOTAA64.EFI", "BOOTX64.EFI"])).architecture, .arm64)
        XCTAssertEqual(ArchitectureProbe.probeInstallMedia(try makeISO("none", loaders: [])).architecture, .unknown)
    }

    // MARK: New VM and live media

    func testCreateFromISOThenEjectAndReattachWhileRunning() async throws {
        let iso = try makeISO("installer", loaders: ["BOOTAA64.EFI"])
        var factory = VMFactory()
        factory.store = VMLibraryStore(rootURL: directory.appendingPathComponent("library"))
        let record = try factory.createFromISO(NewVMSettings(
            name: "Ubuntu Test", isoURL: iso, diskSizeGB: 8, cpuCount: 1, memoryMB: 1024,
            networkMode: .none, bridgedInterfaceID: nil))

        let vmDirectory = factory.store.directory(for: record)
        let disk = vmDirectory.appendingPathComponent(VMFiles.disk(0))
        let attributes = try FileManager.default.attributesOfItem(atPath: disk.path)
        XCTAssertEqual(attributes[.size] as? UInt64, 8 * 1_073_741_824)
        XCTAssertEqual(record.isoPath, iso.path)
        XCTAssertEqual(factory.store.loadAll().map(\.id), [record.id])

        let controller = VMController(vmID: record.id)
        await controller.start(record: record, directory: vmDirectory)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.attachedMediaPath, iso.path)
        XCTAssertTrue(controller.mediaAttachedAtBoot)
        // A boot-time ISO cannot be unplugged live; ejecting drops it from the next start.
        let result = await controller.ejectMedia()
        XCTAssertEqual(result, .atNextStart)
        XCTAssertEqual(controller.attachedMediaPath, iso.path)
        await controller.forceStop()
    }

    func testConsoleInputFIFO() throws {
        let handle = try XCTUnwrap(VMConfigurationBuilder.openConsoleInput(in: directory))
        let path = directory.appendingPathComponent(VMFiles.consoleInput).path
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
        let writer = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        writer.write(Data("root\n".utf8))
        try writer.close()
        XCTAssertEqual(handle.availableData, Data("root\n".utf8))
        // Reopening reuses the FIFO instead of failing.
        XCTAssertNotNil(VMConfigurationBuilder.openConsoleInput(in: directory))
    }

    /// Boots a real installer ISO, logs in on the serial console through console.in and checks
    /// the live system runs from the ISO on virtio block. Opt in with
    /// `TEST_RUNNER_PVMRUNNER_LIVE_ISO=/path/to/ubuntu-arm64.iso xcodebuild test …`.
    func testBootsRealInstallerISOFromVirtioBlock() async throws {
        guard let isoPath = ProcessInfo.processInfo.environment["PVMRUNNER_LIVE_ISO"] else {
            throw XCTSkip("Set PVMRUNNER_LIVE_ISO to an ARM64 Linux live ISO")
        }
        var factory = VMFactory()
        factory.store = VMLibraryStore(rootURL: directory.appendingPathComponent("library"))
        let record = try factory.createFromISO(NewVMSettings(
            name: "Live ISO", isoURL: URL(fileURLWithPath: isoPath), diskSizeGB: 16, cpuCount: 4,
            memoryMB: 6144, networkMode: .nat, bridgedInterfaceID: nil))
        let vmDirectory = factory.store.directory(for: record)
        let log = vmDirectory.appendingPathComponent(VMFiles.consoleLog)
        let controller = VMController(vmID: record.id)
        await controller.start(record: record, directory: vmDirectory)
        XCTAssertNil(controller.errorMessage)
        defer { Task { @MainActor in await controller.forceStop() } }

        func waitFor(_ text: String, seconds: Int) async throws -> String {
            for _ in 0..<seconds {
                let contents = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if contents.contains(text) { return contents }
                try await Task.sleep(for: .seconds(1))
            }
            XCTFail("Timed out waiting for \(text)")
            return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        }
        func type(_ text: String) throws {
            let writer = try XCTUnwrap(FileHandle(forWritingAtPath: vmDirectory.appendingPathComponent(VMFiles.consoleInput).path))
            writer.write(Data(text.utf8))
            try writer.close()
        }

        _ = try await waitFor("login:", seconds: 300)
        try type("ubuntu\n")
        try await Task.sleep(for: .seconds(5))
        try type("echo MARK-$(uname -m); lsblk -dno NAME,TRAN,SIZE; findmnt -no SOURCE /cdrom; echo END-$((40+2))\n")
        let output = try await waitFor("END-42", seconds: 60)
        print(output.suffix(800))
        XCTAssertTrue(output.contains("MARK-aarch64"))
        XCTAssertTrue(output.contains("/dev/vdb"), "live medium should be the virtio ISO")
        await controller.forceStop()
    }
}
