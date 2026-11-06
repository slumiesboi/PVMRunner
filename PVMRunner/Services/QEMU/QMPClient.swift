import Foundation

enum QMPError: LocalizedError {
    case connectFailed(String)
    case disconnected
    case command(String)

    var errorDescription: String? {
        switch self {
        case .connectFailed(let detail): return "Could not connect to QEMU's control socket: \(detail)"
        case .disconnected: return "QEMU closed its control connection."
        case .command(let detail): return "QEMU rejected the command: \(detail)"
        }
    }
}

/// A minimal QEMU Machine Protocol client over a Unix socket: JSON commands with replies
/// matched by id, plus asynchronous events (STOP, RESUME, SHUTDOWN, …).
final class QMPClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var closed = false
    /// Called on a background thread with each event name and its data.
    var onEvent: (@Sendable (String, [String: Any]) -> Void)?

    init(socketPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QMPError.connectFailed(String(cString: strerror(errno))) }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw QMPError.connectFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw QMPError.connectFailed(message)
        }
    }

    deinit { close(fd) }

    /// Reads the greeting, enables commands and starts the reader thread.
    func handshake() throws {
        var reader = LineReader(fd: fd)
        guard reader.readLine() != nil else { throw QMPError.disconnected }
        try writeJSON(["execute": "qmp_capabilities"])
        guard reader.readLine() != nil else { throw QMPError.disconnected }
        let thread = Thread { [weak self] in self?.readLoop(reader) }
        thread.name = "QMP reader"
        thread.start()
    }

    @discardableResult
    func execute(_ command: String, arguments: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !closed else {
                lock.unlock()
                continuation.resume(throwing: QMPError.disconnected)
                return
            }
            nextID += 1
            let id = nextID
            pending[id] = continuation
            lock.unlock()
            var message: [String: Any] = ["execute": command, "id": id]
            if let arguments { message["arguments"] = arguments }
            do {
                try writeJSON(message)
            } catch {
                lock.lock()
                let waiting = pending.removeValue(forKey: id)
                lock.unlock()
                waiting?.resume(throwing: error)
            }
        }
    }

    func disconnect() {
        shutdown(fd, SHUT_RDWR)
    }

    private func writeJSON(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw QMPError.disconnected
                }
                offset += sent
            }
        }
    }

    private func readLoop(_ initial: LineReader) {
        var reader = initial
        while let line = reader.readLine() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let event = object["event"] as? String {
                onEvent?(event, object["data"] as? [String: Any] ?? [:])
            } else if let id = object["id"] as? Int {
                lock.lock()
                let continuation = pending.removeValue(forKey: id)
                lock.unlock()
                if let error = object["error"] as? [String: Any] {
                    continuation?.resume(throwing: QMPError.command(error["desc"] as? String ?? "unknown error"))
                } else {
                    continuation?.resume(returning: object["return"] ?? [:])
                }
            }
        }
        lock.lock()
        closed = true
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume(throwing: QMPError.disconnected) }
        onEvent?("DISCONNECTED", [:])
    }
}

/// Splits a socket's byte stream into newline-terminated messages.
private struct LineReader {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    mutating func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
