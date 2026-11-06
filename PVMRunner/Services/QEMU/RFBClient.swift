import CoreGraphics
import Foundation

/// A small RFB (VNC) 3.8 client for QEMU's display over a Unix socket. It speaks the subset
/// QEMU needs: no authentication, 32-bit true colour Raw and CopyRect updates, desktop
/// resizes, and QEMU's extended key events (raw PC scancodes, so keyboard layouts are left
/// to the guest).
final class RFBClient: @unchecked Sendable {
    /// Called on the main queue with each completed frame.
    var onFrame: (@MainActor (CGImage) -> Void)?
    /// Called on the main queue when the connection ends.
    var onDisconnect: (@MainActor () -> Void)?

    private let socketPath: String
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var width = 0
    private var height = 0
    private var pixels: [UInt8] = []
    private var stopped = false

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Connects (retrying while QEMU starts up) and runs the receive loop on its own thread.
    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "VNC"
        thread.start()
    }

    func stop() {
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    // MARK: - Input

    /// Sends a key by PC scancode (QEMU "qnum": E0-prefixed keys are 0x80 | code).
    func sendKey(scancode: UInt32, down: Bool) {
        var message = Data([255, 0])
        message.appendBE(UInt16(down ? 1 : 0))
        message.appendBE(UInt32(0))
        message.appendBE(scancode)
        write(message)
    }

    /// Absolute pointer position in framebuffer pixels; buttons bit 0 left, 1 middle, 2 right,
    /// 3/4 wheel up/down, 5/6 wheel left/right.
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        var message = Data([5, buttons])
        message.appendBE(UInt16(clamping: max(0, min(x, width - 1))))
        message.appendBE(UInt16(clamping: max(0, min(y, height - 1))))
        write(message)
    }

    var framebufferSize: CGSize { CGSize(width: width, height: height) }

    // MARK: - Protocol

    private func run() {
        defer {
            let callback = onDisconnect
            DispatchQueue.main.async { MainActor.assumeIsolated { callback?() } }
        }
        guard connectWithRetry() else { return }
        do {
            try handshake()
            try receiveLoop()
        } catch {
            // Connection closed: the VM stopped.
        }
    }

    private func connectWithRetry() -> Bool {
        for _ in 0..<200 where !stopped {
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { return false }
            var nosigpipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(socketFD); return false }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                path.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 {
                fd = socketFD
                return true
            }
            close(socketFD)
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func handshake() throws {
        _ = try read(12)  // "RFB 003.008\n"
        write(Data("RFB 003.008\n".utf8))
        let typeCount = Int(try read(1)[0])
        guard typeCount > 0 else { throw RFBError.refused }
        let types = try read(typeCount)
        guard types.contains(1) else { throw RFBError.refused }
        write(Data([1]))  // security type None
        guard try readU32() == 0 else { throw RFBError.refused }
        write(Data([1]))  // ClientInit: shared
        width = Int(try readU16())
        height = Int(try readU16())
        _ = try read(16)  // server pixel format, replaced below
        _ = try read(Int(try readU32()))  // desktop name
        pixels = [UInt8](repeating: 0, count: width * height * 4)

        // SetPixelFormat: 32 bpp, depth 24, little endian, true colour, BGRX in memory.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.appendBE(UInt16(255)); format.appendBE(UInt16(255)); format.appendBE(UInt16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        write(format)
        // SetEncodings: Raw, CopyRect, DesktopSize, QEMU extended key event.
        let encodings: [Int32] = [1, 0, -223, -258]
        var setEncodings = Data([2, 0])
        setEncodings.appendBE(UInt16(encodings.count))
        encodings.forEach { setEncodings.appendBE(UInt32(bitPattern: $0)) }
        write(setEncodings)
        requestUpdate(incremental: false)
    }

    private func receiveLoop() throws {
        while !stopped {
            switch try read(1)[0] {
            case 0: try readFramebufferUpdate()
            case 1:  // SetColourMapEntries (unused in true colour)
                _ = try read(3)
                _ = try read(Int(try readU16()) * 6)
            case 2: break  // Bell
            case 3:  // ServerCutText
                _ = try read(3)
                _ = try read(Int(try readU32()))
            default: throw RFBError.protocolError
            }
        }
    }

    private func readFramebufferUpdate() throws {
        _ = try read(1)
        let rectangles = Int(try readU16())
        for _ in 0..<rectangles {
            let x = Int(try readU16()), y = Int(try readU16())
            let w = Int(try readU16()), h = Int(try readU16())
            let encoding = Int32(bitPattern: try readU32())
            switch encoding {
            case 0:
                let data = try read(w * h * 4)
                data.withUnsafeBytes { source in
                    for row in 0..<h where y + row < height {
                        let count = min(w, width - x) * 4
                        guard count > 0 else { continue }
                        pixels.withUnsafeMutableBytes { target in
                            target.baseAddress!.advanced(by: ((y + row) * width + x) * 4)
                                .copyMemory(from: source.baseAddress!.advanced(by: row * w * 4), byteCount: count)
                        }
                    }
                }
            case 1:
                let sourceX = Int(try readU16()), sourceY = Int(try readU16())
                copyRect(from: (sourceX, sourceY), to: (x, y), size: (w, h))
            case -223:
                width = w
                height = h
                pixels = [UInt8](repeating: 0, count: w * h * 4)
            case -258:
                break  // the server supports extended key events
            default:
                throw RFBError.protocolError
            }
        }
        publishFrame()
        requestUpdate(incremental: true)
    }

    private func copyRect(from source: (Int, Int), to target: (Int, Int), size: (Int, Int)) {
        let rows = Array(0..<size.1)
        for row in (source.1 < target.1 ? rows.reversed() : rows) {
            let from = ((source.1 + row) * width + source.0) * 4
            let to = ((target.1 + row) * width + target.0) * 4
            let count = size.0 * 4
            guard from >= 0, to >= 0, from + count <= pixels.count, to + count <= pixels.count else { continue }
            pixels.withUnsafeMutableBytes { buffer in
                buffer.baseAddress!.advanced(by: to).copyMemory(from: buffer.baseAddress!.advanced(by: from), byteCount: count)
            }
        }
    }

    private func publishFrame() {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                         | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        let callback = onFrame
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(image) } }
    }

    private func requestUpdate(incremental: Bool) {
        var message = Data([3, incremental ? 1 : 0])
        message.appendBE(UInt16(0)); message.appendBE(UInt16(0))
        message.appendBE(UInt16(clamping: width)); message.appendBE(UInt16(clamping: height))
        write(message)
    }

    // MARK: - Socket I/O

    private func write(_ data: Data) {
        guard fd >= 0 else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += sent
            }
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + offset, count - offset, 0) }
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { throw RFBError.closed }
            offset += received
        }
        return data
    }

    private func readU16() throws -> UInt16 {
        let data = try read(2)
        return UInt16(data[0]) << 8 | UInt16(data[1])
    }

    private func readU32() throws -> UInt32 {
        let data = try read(4)
        return data.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

enum RFBError: Error {
    case closed, refused, protocolError
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
