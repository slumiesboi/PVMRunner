import Darwin
import XCTest
@testable import PVMRunner

/// Drives the relay against a fake socket_vmnet (the other end of a stream socket pair).
final class SocketVmnetRelayTests: XCTestCase {
    private var fakeHostFD: Int32 = -1
    private var relay: SocketVmnetRelay!

    override func setUpWithError() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        fakeHostFD = pair[0]
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fakeHostFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        relay = try SocketVmnetRelay(connectedStreamFD: pair[1])
        setsockopt(relay.vmFileHandle.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
    }

    override func tearDown() {
        relay.stop()
        close(fakeHostFD)
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            guard n > 0 else { break }
            offset += n
        }
        return Array(buffer.prefix(offset))
    }

    func testVMFrameIsLengthPrefixedOnStream() {
        let frame: [UInt8] = Array(0..<60)
        XCTAssertEqual(frame.withUnsafeBytes { send(relay.vmFileHandle.fileDescriptor, $0.baseAddress, 60, 0) }, 60)
        XCTAssertEqual(readExactly(fakeHostFD, 4), [0, 0, 0, 60])
        XCTAssertEqual(readExactly(fakeHostFD, 60), frame)
    }

    func testStreamFramesArriveAsSeparateDatagrams() {
        let first: [UInt8] = Array(repeating: 0xAA, count: 64)
        let second: [UInt8] = Array(repeating: 0xBB, count: 1514)
        var bytes: [UInt8] = []
        for frame in [first, second] {
            withUnsafeBytes(of: UInt32(frame.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: frame)
        }
        // Write in awkward chunks so frames straddle reads, as a real stream would deliver them.
        for chunk in stride(from: 0, to: bytes.count, by: 37) {
            let end = min(chunk + 37, bytes.count)
            _ = bytes[chunk..<end].withUnsafeBytes { write(fakeHostFD, $0.baseAddress, $0.count) }
        }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let vmFD = relay.vmFileHandle.fileDescriptor
        let n1 = buffer.withUnsafeMutableBytes { recv(vmFD, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(Array(buffer.prefix(max(0, n1))), first)
        let n2 = buffer.withUnsafeMutableBytes { recv(vmFD, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(Array(buffer.prefix(max(0, n2))), second)
    }

    func testUnreachableSocketIsReported() {
        XCTAssertFalse(SocketVmnetRelay.isReachable(path: "/tmp/pvmrunner-no-such-socket"))
        XCTAssertThrowsError(try SocketVmnetRelay(socketPath: "/tmp/pvmrunner-no-such-socket"))
    }
}

extension SocketVmnetRelayTests {
    /// When the VM stops reading, frames are dropped instead of blocking the stream reader.
    func testFullVMBufferDropsFramesWithoutStalling() {
        let frame = [UInt8](repeating: 0xCC, count: 1500)
        var framed: [UInt8] = []
        withUnsafeBytes(of: UInt32(frame.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(contentsOf: frame)
        // Far more than the VM socket's 4 MB receive buffer, written while nobody reads the VM side.
        let writer = Thread { [fakeHostFD] in
            for _ in 0..<6000 {
                _ = framed.withUnsafeBytes { write(fakeHostFD, $0.baseAddress, $0.count) }
            }
        }
        writer.start()
        let deadline = Date().addingTimeInterval(10)
        while relay.frameCounts.hostToVM + relay.droppedFrames < 6000 && Date() < deadline {
            usleep(20_000)
        }
        XCTAssertEqual(relay.frameCounts.hostToVM + relay.droppedFrames, 6000, "the relay stalled")
        XCTAssertGreaterThan(relay.droppedFrames, 0)
    }
}
