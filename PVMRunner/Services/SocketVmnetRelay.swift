import Darwin
import Foundation

enum SocketVmnetError: LocalizedError {
    case pathTooLong(String)
    case connectFailed(path: String, errno: Int32)
    case socketFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "The socket_vmnet path “\(path)” is too long for a Unix socket."
        case .connectFailed(let path, let code):
            let reason = String(cString: strerror(code))
            return "Could not connect to socket_vmnet at \(path) (\(reason)). Is the socket_vmnet helper running?"
        case .socketFailed(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Bridges a VM network device to a running `socket_vmnet` helper.
///
/// Virtualization.framework's `VZFileHandleNetworkDeviceAttachment` exchanges one Ethernet
/// frame per datagram on a connected `SOCK_DGRAM` socket. socket_vmnet speaks the QEMU
/// stream protocol instead: each frame is preceded by its length as a 4-byte big-endian
/// integer. This relay owns one end of a datagram socket pair (the other end goes to the
/// VM) plus the stream connection, and copies frames between them on two threads.
///
/// socket_vmnet runs as root and uses vmnet's bridged mode, which is what makes bridged
/// networking possible without the restricted com.apple.vm.networking entitlement.
final class SocketVmnetRelay: @unchecked Sendable {
    /// Hand this to `VZFileHandleNetworkDeviceAttachment(fileHandle:)`.
    let vmFileHandle: FileHandle

    private let relayFD: Int32
    private let hostFD: Int32
    private let lock = NSLock()
    private var isClosed = false
    private var sentToHost = 0
    private var sentToVM = 0
    private var droppedToVM = 0

    /// Frames dropped because the guest was not taking them, for diagnostics.
    var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedToVM
    }

    private func recordDrop() {
        lock.lock(); defer { lock.unlock() }
        droppedToVM += 1
    }

    /// Frames relayed in each direction since start, for diagnostics.
    var frameCounts: (vmToHost: Int, hostToVM: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sentToHost, sentToVM)
    }

    private func recordFrame(toHost: Bool) {
        lock.lock(); defer { lock.unlock() }
        if toHost { sentToHost += 1 } else { sentToVM += 1 }
    }

    /// Largest frame accepted from either side (jumbo frames included).
    static let maxFrameSize = 65_535

    static func defaultSocketPath(interface: String) -> String {
        "/var/run/socket_vmnet.bridged.\(interface)"
    }

    /// Returns true when something accepts connections at `path`.
    static func isReachable(path: String) -> Bool {
        guard let fd = try? connectStream(path: path) else { return false }
        close(fd)
        return true
    }

    convenience init(socketPath: String) throws {
        try self.init(connectedStreamFD: Self.connectStream(path: socketPath))
    }

    /// Takes ownership of an already connected stream socket (used by tests).
    init(connectedStreamFD: Int32) throws {
        hostFD = connectedStreamFD
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            let code = errno
            close(connectedStreamFD)
            throw SocketVmnetError.socketFailed("socketpair", code)
        }
        // Apple recommends a receive buffer at least 4x the send buffer for file handle attachments.
        for fd in pair {
            Self.setOption(fd, SO_SNDBUF, 1 << 20)
            Self.setOption(fd, SO_RCVBUF, 4 << 20)
            Self.setOption(fd, SO_NOSIGPIPE, 1)
        }
        Self.setOption(hostFD, SO_NOSIGPIPE, 1)

        vmFileHandle = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        relayFD = pair[1]

        let vmToHost = Thread { [self] in pumpVMToHost() }
        vmToHost.name = "socket_vmnet vm→host"
        vmToHost.start()
        let hostToVM = Thread { [self] in pumpHostToVM() }
        hostToVM.name = "socket_vmnet host→vm"
        hostToVM.start()
    }

    /// The pump threads hold strong references, so this only runs after both have exited
    /// and nothing can still be using the descriptors.
    deinit {
        close(hostFD)
        close(relayFD)
    }

    /// Shuts both connections down; the pump threads wake up, exit, and release the relay.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(hostFD, SHUT_RDWR)
        shutdown(relayFD, SHUT_RDWR)
    }

    // MARK: - Pumps

    private func pumpVMToHost() {
        var frame = [UInt8](repeating: 0, count: Self.maxFrameSize)
        while true {
            let count = frame.withUnsafeMutableBytes { recv(relayFD, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            var header = UInt32(count).bigEndian
            let ok = withUnsafeBytes(of: &header) { headerBytes in
                frame.withUnsafeBytes { frameBytes in
                    Self.writeAll(hostFD, headerBytes.baseAddress!, 4)
                        && Self.writeAll(hostFD, frameBytes.baseAddress!, count)
                }
            }
            guard ok else { break }
            recordFrame(toHost: true)
        }
        stop()
    }

    private func pumpHostToVM() {
        var frame = [UInt8](repeating: 0, count: Self.maxFrameSize)
        var header: UInt32 = 0
        while true {
            let gotHeader = withUnsafeMutableBytes(of: &header) { Self.readAll(hostFD, $0.baseAddress!, 4) }
            guard gotHeader else { break }
            let length = Int(UInt32(bigEndian: header))
            guard length > 0, length <= Self.maxFrameSize else { break }
            let gotFrame = frame.withUnsafeMutableBytes { Self.readAll(hostFD, $0.baseAddress!, length) }
            guard gotFrame else { break }
            // Never block here: while the guest is not taking frames (e.g. early boot) a blocked
            // send would stop this thread reading the stream and stall socket_vmnet as well.
            // A full VM receive buffer drops the frame, like a busy NIC would.
            let sent = frame.withUnsafeBytes { send(relayFD, $0.baseAddress, length, MSG_DONTWAIT) }
            if sent > 0 {
                recordFrame(toHost: false)
            } else if errno == ENOBUFS || errno == EAGAIN || errno == EINTR {
                recordDrop()
            } else {
                break
            }
        }
        stop()
    }

    // MARK: - POSIX helpers

    private static func connectStream(path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw SocketVmnetError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketVmnetError.socketFailed("socket", errno) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketVmnetError.connectFailed(path: path, errno: code)
        }
        return fd
    }

    private static func setOption(_ fd: Int32, _ option: Int32, _ value: Int32) {
        var value = value
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = write(fd, pointer + offset, count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private static func readAll(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let received = read(fd, pointer + offset, count - offset)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { return false }
            offset += received
        }
        return true
    }
}
