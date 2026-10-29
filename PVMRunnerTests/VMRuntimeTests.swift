import Virtualization
import XCTest
@testable import PVMRunner

/// Boots a Linux configuration with a blank disk (the EFI firmware runs, finds nothing
/// to boot and waits), which exercises VMConfigurationBuilder and VMController end to end.
@MainActor
final class VMRuntimeTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent(VMFiles.disk(0))
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(network: NetworkMode) -> VMRecord {
        VMRecord(id: UUID(), name: "Test", guestOS: .linux, guestOSDescription: "Linux",
                 cpuCount: 2, memoryMB: 1024, diskFileNames: [VMFiles.disk(0)],
                 networkMode: network, bridgedInterfaceID: nil, macAddress: "00:1c:42:a1:b2:c3",
                 isoPath: nil, displayWidth: 1280, displayHeight: 800,
                 sourcePVMPath: "/tmp/Test.pvm", importedAt: Date())
    }

    func testLinuxConfigurationValidates() throws {
        let output = try VMConfigurationBuilder.build(record: record(network: .nat), directory: directory)
        XCTAssertEqual(output.effectiveNetworkMode, .nat)
        XCTAssertEqual(output.configuration.networkDevices.first?.macAddress.string, "00:1c:42:a1:b2:c3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(VMFiles.efiVariableStore).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(VMFiles.machineIdentifier).path))
    }

    func testBridgedFallsBackToNATWithoutEntitlement() throws {
        try XCTSkipIf(VMConfigurationBuilder.hasBridgedNetworkingEntitlement, "build has the networking entitlement")
        let output = try VMConfigurationBuilder.build(record: record(network: .bridged), directory: directory)
        XCTAssertEqual(output.effectiveNetworkMode, .nat)
        XCTAssertFalse(output.notices.isEmpty)
    }

    func testStartPauseResumeForceStop() async throws {
        let controller = VMController(vmID: UUID())
        await controller.start(record: record(network: .none), directory: directory)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.state, .running)

        await controller.pause()
        XCTAssertEqual(controller.state, .paused)
        await controller.resume()
        XCTAssertEqual(controller.state, .running)

        await controller.forceStop()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.virtualMachine)
    }
}

extension VMRuntimeTests {
    func testSocketVmnetFallsBackToNATWhenHelperIsMissing() throws {
        var vm = record(network: .socketVmnet)
        vm.socketVmnetPath = "/tmp/pvmrunner-no-such-socket"
        let output = try VMConfigurationBuilder.build(record: vm, directory: directory)
        XCTAssertEqual(output.effectiveNetworkMode, .nat)
        XCTAssertNil(output.relay)
        XCTAssertTrue(output.notices.contains { $0.contains("socket_vmnet") })
    }
}

extension VMRuntimeTests {
    func testStartReportsVMAlreadyRunningElsewhere() async throws {
        let disk = directory.appendingPathComponent(VMFiles.disk(0))
        let fd = open(disk.path, O_RDONLY)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let controller = VMController(vmID: UUID())
        await controller.start(record: record(network: .none), directory: directory)
        XCTAssertEqual(controller.state, .error)
        XCTAssertTrue(controller.errorMessage?.contains("already running") == true)
        XCTAssertNil(controller.virtualMachine)
    }
}
