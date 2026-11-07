import AppKit
import XCTest
@testable import PVMRunner

/// The QEMU engine used for Windows guests: installer detection, the command line, and a
/// real boot through `VMController` with the in-app VNC client attached.
@MainActor
final class QEMUEngineTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A small UDF + ISO 9660 image laid out like a Windows installer.
    private func makeWindowsISO(loader: String = "bootaa64.efi") throws -> URL {
        let root = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 4096).write(to: root.appendingPathComponent("efi/boot/\(loader)"))
        try Data(repeating: 0x57, count: 4096).write(to: root.appendingPathComponent("sources/install.wim"))
        let iso = directory.appendingPathComponent("\(UUID().uuidString).iso")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-quiet", "-udf", "-iso", "-joliet", "-o", iso.path, root.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return iso
    }

    private func windowsRecord(iso: URL?, driversISO: URL? = nil) throws -> (VMRecord, URL) {
        var factory = VMFactory()
        factory.windowsDriversISO = driversISO
        factory.store = VMLibraryStore(rootURL: directory.appendingPathComponent("library"))
        let record = try factory.createFromISO(NewVMSettings(
            name: "Win, Test", isoURL: iso ?? directory.appendingPathComponent("none.iso"), diskSizeGB: 2,
            cpuCount: 2, memoryMB: 2048, networkMode: .nat, bridgedInterfaceID: nil, guestOS: .windows))
        return (record, factory.store.directory(for: record))
    }

    func testDetectsWindowsInstaller() throws {
        let arm = ArchitectureProbe.probeInstallMedia(try makeWindowsISO())
        XCTAssertTrue(arm.isWindows)
        XCTAssertEqual(arm.architecture, .arm64)
    }

    func testDetectsX64WindowsInstaller() throws {
        let x64 = ArchitectureProbe.probeInstallMedia(try makeWindowsISO(loader: "bootx64.efi"))
        XCTAssertTrue(x64.isWindows)
        XCTAssertEqual(x64.architecture, .x86)
    }

    func testWindowsVMFiles() throws {
        let (record, vmDirectory) = try windowsRecord(iso: try makeWindowsISO())
        XCTAssertEqual(record.guestOS, .windows)
        XCTAssertEqual(record.guestOSDescription, "Windows 11")
        let vars = try FileManager.default.attributesOfItem(atPath: vmDirectory.appendingPathComponent(VMFiles.qemuVariableStore).path)
        XCTAssertEqual(vars[.size] as? UInt64, 64 * 1024 * 1024)
        let store = try Data(contentsOf: vmDirectory.appendingPathComponent(VMFiles.qemuVariableStore))
        XCTAssertNotNil(store.range(of: QEMUVariableStore.platformConfig(width: 1024, height: 768)))
        XCTAssertThrowsError(try VMConfigurationBuilder.build(record: record, directory: vmDirectory))
    }

    func testCommandLine() throws {
        let tools = QEMUTools(qemu: URL(fileURLWithPath: "/q"), firmware: URL(fileURLWithPath: "/fw,code.fd"),
                              swtpm: URL(fileURLWithPath: "/s"))
        let (record, vmDirectory) = try windowsRecord(iso: try makeWindowsISO())
        let run = QEMUCommandBuilder.RunPaths(directory: directory.appendingPathComponent("run"))
        let output = try QEMUCommandBuilder.build(record: record, directory: vmDirectory, run: run, tools: tools)
        let args = output.arguments.joined(separator: " ")

        XCTAssertTrue(args.contains("-accel hvf"))
        XCTAssertTrue(args.contains("file=/fw,,code.fd"), "commas in paths must be doubled")
        XCTAssertTrue(args.contains("tpm-tis-device,tpmdev=tpm0,ppi=off"))
        XCTAssertTrue(args.contains("nvme,drive=disk0"))
        XCTAssertTrue(args.contains("usb-storage,id=bootcd,drive=cd0,removable=on,bootindex=0"))
        XCTAssertTrue(args.contains("file=fat:"))
        XCTAssertTrue(args.contains("-netdev user,id=net0"))
        XCTAssertTrue(output.isoAttached)
        XCTAssertEqual(output.effectiveNetworkMode, .nat)
        let answerFile = try String(contentsOf: vmDirectory.appendingPathComponent("\(VMFiles.windowsSetup)/autounattend.xml"), encoding: .utf8)
        XCTAssertTrue(answerFile.contains("BypassSecureBootCheck"))

        XCTAssertFalse(args.contains("iothread"), "NVMe needs no I/O thread")

        var preparing = record
        preparing.diskBus = .preparingVirtio
        let prepareArgs = try QEMUCommandBuilder.build(record: preparing, directory: vmDirectory, run: run, tools: tools)
            .arguments.joined(separator: " ")
        XCTAssertTrue(prepareArgs.contains("-object iothread,id=io0"))
        XCTAssertTrue(prepareArgs.contains("nvme,drive=disk0"))
        XCTAssertTrue(prepareArgs.contains("virtio-blk-pci,id=virtioprobe,drive=probe,iothread=io0"))
        let probe = vmDirectory.appendingPathComponent(VMFiles.virtioProbe)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: probe.path)[.size] as? UInt64, 16 * 1024 * 1024)

        var virtio = record
        virtio.diskBus = .virtio
        let virtioArgs = try QEMUCommandBuilder.build(record: virtio, directory: vmDirectory, run: run, tools: tools)
            .arguments.joined(separator: " ")
        XCTAssertTrue(virtioArgs.contains("virtio-blk-pci,id=vdisk0,drive=disk0,iothread=io0,serial=PVM0001,bootindex=1"))
        XCTAssertTrue(virtioArgs.contains("nvme,id=nvmeprobe,drive=probe"), "a spare NVMe disk keeps switching back possible")
        XCTAssertFalse(virtioArgs.contains("nvme,drive=disk0") || virtioArgs.contains("virtioprobe"))
        _ = try QEMUCommandBuilder.build(record: record, directory: vmDirectory, run: run, tools: tools)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.path), "the spare disk is removed on NVMe")

        var noISO = record
        noISO.isoPath = nil
        noISO.networkMode = .none
        let plain = try QEMUCommandBuilder.build(record: noISO, directory: vmDirectory, run: run, tools: tools)
        XCTAssertFalse(plain.arguments.contains { $0.contains("id=bootcd") || $0.contains("fat:") })
        XCTAssertFalse(plain.arguments.contains("-netdev"))
    }

    /// ramfb by default; virtio-gpu once the display driver is in, with ramfb alongside while
    /// an ISO is attached, each screen on its own VNC socket.
    func testDisplayModes() throws {
        let tools = QEMUTools(qemu: URL(fileURLWithPath: "/q"), firmware: URL(fileURLWithPath: "/fw"),
                              swtpm: URL(fileURLWithPath: "/s"))
        var (record, vmDirectory) = try windowsRecord(iso: try makeWindowsISO())
        let run = QEMUCommandBuilder.RunPaths(directory: directory.appendingPathComponent("run"))
        func build(_ display: QEMUDisplay?, iso: Bool = true) throws -> QEMUCommandBuilder.Output {
            record.display = display
            var copy = record
            if !iso { copy.isoPath = nil }
            return try QEMUCommandBuilder.build(record: copy, directory: vmDirectory, run: run, tools: tools)
        }

        let basic = try build(nil)
        XCTAssertEqual(basic.screens, .ramfb)
        XCTAssertTrue(basic.arguments.contains("ramfb,id=fb"))
        XCTAssertFalse(basic.arguments.contains { $0.hasPrefix("virtio-gpu") })
        XCTAssertTrue(basic.arguments.contains("unix:\(run.vnc)"))

        let preparing = try build(.preparingVirtio, iso: false)
        XCTAssertEqual(preparing.screens, .both)
        XCTAssertTrue(preparing.arguments.contains("ramfb,id=fb"))
        XCTAssertTrue(preparing.arguments.contains("virtio-gpu-pci,id=gpu,xres=1920,yres=1200"))
        XCTAssertTrue(preparing.arguments.contains("unix:\(run.vnc),display=fb"))
        XCTAssertTrue(preparing.arguments.contains("unix:\(run.gpuVNC),id=gpuvnc,display=gpu"))

        XCTAssertEqual(try build(.virtio).screens, .both, "the ISO's boot prompt needs ramfb")
        record.displayWidth = 2560
        record.displayHeight = 1440
        let virtio = try build(.virtio, iso: false)
        XCTAssertEqual(virtio.screens, .gpu)
        XCTAssertFalse(virtio.arguments.contains { $0.hasPrefix("ramfb") })
        XCTAssertTrue(virtio.arguments.contains("virtio-gpu-pci,id=gpu,xres=2560,yres=1440"))
        XCTAssertTrue(virtio.arguments.contains("unix:\(run.vnc)"))
    }

    /// The screen view treats QEMU's black "Display output is not active" placeholder as unused.
    func testBlankScreenDetection() throws {
        func image(_ draw: (CGContext) -> Void) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
            draw(context)
            return try XCTUnwrap(context.makeImage())
        }
        let placeholder = try image { context in
            context.setFillColor(CGColor(gray: 0.7, alpha: 1))
            context.fill(CGRect(x: 520, y: 395, width: 232, height: 10))
        }
        XCTAssertTrue(QEMUScreenView.isBlank(placeholder))
        let desktop = try image { context in
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 60, width: 1280, height: 740))
        }
        XCTAssertFalse(QEMUScreenView.isBlank(desktop))
    }

    /// With the virtio-win ISO downloaded, a new VM starts on virtio disk and screen, the setup
    /// drive carries the storage and display drivers for Setup, and the answer file installs
    /// the rest at first sign-in.
    func testSetupDriveCarriesVirtioDrivers() throws {
        let (plain, _) = try windowsRecord(iso: try makeWindowsISO())
        XCTAssertNil(plain.diskBus, "without drivers a new VM uses NVMe")
        XCTAssertNil(plain.display, "and the basic screen")
        guard let driversISO = WindowsDrivers.installedISO else {
            throw XCTSkip("The virtio-win ISO isn't downloaded.")
        }
        let (record, vmDirectory) = try windowsRecord(iso: try makeWindowsISO(), driversISO: driversISO)
        XCTAssertEqual(record.diskBus, .virtio)
        XCTAssertEqual(record.display, .virtio)

        let setup = try WindowsSetupFiles.write(in: vmDirectory)
        try WindowsSetupFiles.addDrivers(in: setup, from: driversISO)
        let driver = setup.appendingPathComponent("$WinPEDriver$/viostor")
        let files = try FileManager.default.contentsOfDirectory(atPath: driver.path).sorted()
        XCTAssertEqual(files, ["viostor.cat", "viostor.inf", "viostor.sys"])
        let display = try FileManager.default.contentsOfDirectory(atPath: setup.appendingPathComponent("$WinPEDriver$/viogpudo").path)
        XCTAssertTrue(display.contains("viogpudo.inf") && display.contains("viogpudo.sys"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vmDirectory.appendingPathComponent(".drivers-partial").path))
        XCTAssertTrue(FileManager.default.isDeletableFile(atPath: driver.appendingPathComponent("viostor.sys").path))

        let answerFile = try String(contentsOf: setup.appendingPathComponent("autounattend.xml"), encoding: .utf8)
        let encoded = try XCTUnwrap(answerFile.firstMatch(of: /-EncodedCommand ([A-Za-z0-9+\/=]+)</)?.1)
        let bytes = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        XCTAssertEqual(String(data: bytes, encoding: .utf16LittleEndian), WindowsDrivers.installCommand)
        XCTAssertNoThrow(try XMLDocument(xmlString: answerFile))
    }

    func testBlankDiskDetection() throws {
        let disk = directory.appendingPathComponent("d.img")
        FileManager.default.createFile(atPath: disk.path, contents: Data(count: 4096))
        XCTAssertTrue(QEMUMachine.diskIsBlank(disk))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: 512)
        handle.write(Data("EFI PART".utf8))
        try handle.close()
        XCTAssertFalse(QEMUMachine.diskIsBlank(disk))
    }

    /// Boots the firmware under HVF with a TPM, shows a frame over VNC, pauses, resumes and
    /// powers off. Needs `brew install qemu swtpm`.
    func testBootsAndDisplaysOverVNC() async throws {
        guard QEMUTools.missingPackages.isEmpty else { throw XCTSkip("qemu and swtpm are not installed") }
        let (record, vmDirectory) = try windowsRecord(iso: try makeWindowsISO())
        let controller = VMController(vmID: record.id)
        await controller.start(record: record, directory: vmDirectory)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.state, .running)
        let machine = try XCTUnwrap(controller.qemuMachine)

        let client = RFBClient(socketPath: machine.run.vnc)
        let frame = expectation(description: "frame")
        frame.assertForOverFulfill = false
        var size = CGSize.zero
        var latest: CGImage?
        client.onFrame = { image in
            size = CGSize(width: image.width, height: image.height)
            latest = image
            if image.width == 1024 { frame.fulfill() }
        }
        client.start()
        // The preset variable store puts the firmware screen at 1024 × 768.
        await fulfillment(of: [frame], timeout: 30)
        XCTAssertEqual(size, CGSize(width: 1024, height: 768))
        client.sendPointer(x: 10, y: 10, buttons: 0)
        client.sendKey(scancode: 0x39, down: true)
        client.sendKey(scancode: 0x39, down: false)

        // The window's view draws the guest screen upright: its top/bottom balance matches the frame's.
        let view = QEMUScreenView(socketPath: machine.run.vnc)
        view.frame = NSRect(x: 0, y: 0, width: 512, height: 384)
        try await Task.sleep(for: .seconds(8))  // the firmware reaches its shell, text at the top
        let source = try XCTUnwrap(latest.map(Self.halves))
        let rendered = try XCTUnwrap(Self.halves(of: view))
        XCTAssertGreaterThan(abs(source.top - source.bottom), 0.2, "the frame should not be uniform")
        XCTAssertEqual(source.top > source.bottom, rendered.top > rendered.bottom, "the view must not draw upside down")
        view.disconnect()

        // Media: the boot ISO unplugs live, and another ISO hot-plugs as a USB CD drive.
        XCTAssertTrue(controller.supportsLiveMedia)
        let ejected = await controller.ejectMedia()
        XCTAssertEqual(ejected, .ejected)
        let attached = await controller.attachMedia(try makeWindowsISO())
        XCTAssertTrue(attached)
        XCTAssertNil(controller.errorMessage)
        // Plugged into a USB 3 port, not the slow overflow hub.
        let usb = await machine.usbDevices()
        let line = try XCTUnwrap(usb.split(separator: "\n").first { $0.contains("ID: mediabot") })
        XCTAssertTrue(line.contains("5000 Mb/s"), String(line))
        let mediaAttached = await machine.isMediaAttached
        XCTAssertTrue(mediaAttached)
        XCTAssertFalse(usb.contains("USB Hub"), usb)
        let replaced = await controller.attachMedia(try makeWindowsISO())
        XCTAssertTrue(replaced)
        XCTAssertNil(controller.errorMessage)

        await controller.pause()
        try await waitFor { controller.state == .paused }
        await controller.resume()
        try await waitFor { controller.state == .running }

        await controller.forceStop()
        try await waitFor { controller.state == .stopped && controller.qemuMachine == nil }
        client.stop()
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vmDirectory.appendingPathComponent("\(VMFiles.tpmState)/tpm2-00.permall").path))
    }

    /// Switches an installed Windows VM to virtio through the app's controller: the probe boot
    /// must see Windows load the driver, and the virtio boot must reach Windows' own driver.
    /// Set PVMRUNNER_WINDOWS_VM to a copy of a Windows VM folder (it is modified).
    func testWindowsSwitchesToVirtio() async throws {
        guard let path = ProcessInfo.processInfo.environment["PVMRUNNER_WINDOWS_VM"] else {
            throw XCTSkip("Set PVMRUNNER_WINDOWS_VM to a copy of an installed Windows VM folder")
        }
        let folder = URL(fileURLWithPath: path)
        let store = VMLibraryStore(rootURL: folder.deletingLastPathComponent())
        var record = try XCTUnwrap(store.loadAll().first { store.directory(for: $0).standardizedFileURL == folder.standardizedFileURL })
        record.isoPath = nil

        record.diskBus = .preparingVirtio
        let controller = VMController(vmID: record.id)
        let loaded = expectation(description: "virtio driver loaded")
        controller.onVirtioDriverLoaded = { loaded.fulfill() }
        await controller.start(record: record, directory: folder)
        XCTAssertNil(controller.errorMessage)
        await fulfillment(of: [loaded], timeout: 240)
        await controller.forceStop()
        try await waitFor { controller.state == .stopped && controller.qemuMachine == nil }

        // Windows' driver uses several queues; the firmware only ever uses the first.
        record.diskBus = .virtio
        await controller.start(record: record, directory: folder)
        let machine = try XCTUnwrap(controller.qemuMachine)
        let deadline = Date().addingTimeInterval(240)
        var used = 0
        while used == 0 && Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            used = await machine.virtioQueueUsed(device: "vdisk0", queue: 1)
        }
        XCTAssertGreaterThan(used, 0, "Windows did not start its virtio driver on the boot disk")
        XCTAssertEqual(controller.state, .running)
        await controller.forceStop()
        try await waitFor { controller.state == .stopped && controller.qemuMachine == nil }
    }

    /// Switches an installed Windows VM to virtio-gpu: during the switching start the window
    /// must move to the virtio screen once Windows' display driver draws on it, and the next
    /// start must show Windows on virtio-gpu alone at the chosen resolution.
    /// Set PVMRUNNER_WINDOWS_VM to a copy of a Windows VM folder (it is modified).
    func testWindowsSwitchesToVirtioGPU() async throws {
        guard let path = ProcessInfo.processInfo.environment["PVMRUNNER_WINDOWS_VM"] else {
            throw XCTSkip("Set PVMRUNNER_WINDOWS_VM to a copy of an installed Windows VM folder")
        }
        let folder = URL(fileURLWithPath: path)
        let store = VMLibraryStore(rootURL: folder.deletingLastPathComponent())
        var record = try XCTUnwrap(store.loadAll().first { store.directory(for: $0).standardizedFileURL == folder.standardizedFileURL })
        record.isoPath = nil
        record.display = .preparingVirtio
        record.displayWidth = 1680
        record.displayHeight = 1050

        let controller = VMController(vmID: record.id)
        let loaded = expectation(description: "virtio display driver loaded")
        controller.onVirtioDisplayLoaded = { loaded.fulfill() }
        await controller.start(record: record, directory: folder)
        XCTAssertNil(controller.errorMessage)
        var machine = try XCTUnwrap(controller.qemuMachine)
        XCTAssertEqual(machine.screens, .both)
        let both = QEMUScreenView(socketPath: machine.run.vnc, gpuSocketPath: machine.run.gpuVNC)
        await fulfillment(of: [loaded], timeout: 240)
        try await waitFor(seconds: 120) { both.showsGPU }
        both.disconnect()
        await controller.forceStop()
        try await waitFor { controller.state == .stopped && controller.qemuMachine == nil }

        record.display = .virtio
        await controller.start(record: record, directory: folder)
        machine = try XCTUnwrap(controller.qemuMachine)
        XCTAssertEqual(machine.screens, .gpu)
        let client = RFBClient(socketPath: machine.run.vnc)
        let desktop = expectation(description: "Windows on virtio-gpu")
        desktop.assertForOverFulfill = false
        client.onFrame = { image in
            if image.width == 1680 && image.height == 1050 && !QEMUScreenView.isBlank(image) { desktop.fulfill() }
        }
        client.start()
        await fulfillment(of: [desktop], timeout: 240)
        client.stop()
        await controller.forceStop()
        try await waitFor { controller.state == .stopped && controller.qemuMachine == nil }
    }

    /// Average brightness (0–255) of the top and bottom halves of an image.
    private static func halves(of image: CGImage) -> (top: Double, bottom: Double) {
        let width = 256, height = 192
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Bitmap contexts store the top row first.
        return halves(pixels, width: width, height: height)
    }

    private static func halves(of view: NSView) -> (top: Double, bottom: Double)? {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let data = bitmap.bitmapData else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return halves(Array(UnsafeBufferPointer(start: data, count: width * height * 4)), width: width, height: height)
    }

    private static func halves(_ pixels: [UInt8], width: Int, height: Int) -> (top: Double, bottom: Double) {
        func average(_ rows: Range<Int>) -> Double {
            var total = 0
            for y in rows { for x in 0..<width {
                let offset = (y * width + x) * 4
                total += Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
            } }
            return Double(total) / Double(rows.count * width * 3)
        }
        return (average(0..<height / 2), average(height / 2..<height))
    }

    private func waitFor(seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
