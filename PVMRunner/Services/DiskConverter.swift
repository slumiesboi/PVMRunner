import Foundation

enum DiskConverterError: LocalizedError {
    case qemuImgMissing
    case processFailed(command: String, status: Int32, output: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .qemuImgMissing:
            return "qemu-img was not found at /opt/homebrew/bin/qemu-img or /usr/local/bin/qemu-img."
        case .processFailed(let command, let status, let output):
            let tail = output.split(separator: "\n").suffix(5).joined(separator: "\n")
            return "\(command) failed (exit status \(status)).\n\(tail)"
        case .cancelled:
            return "The conversion was cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .qemuImgMissing:
            return "Install QEMU with Homebrew by running:\n\n    brew install qemu\n\nthen try the import again."
        default:
            return nil
        }
    }
}

/// Converts Parallels disk images to raw images with `qemu-img`.
struct DiskConverter {
    static let qemuImgCandidates = ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img"]

    static func locateQemuImg() -> URL? {
        qemuImgCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Converts `source` into a raw image at `destination`, reporting progress in 0...1.
    /// Writes to a temporary `.partial` file first so a cancelled or failed run never
    /// leaves a truncated image behind. Cancelling the calling task terminates qemu-img.
    func convert(source: URL, format: DiskSourceFormat, to destination: URL,
                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        if format == .raw && source.pathExtension.lowercased() != "hds" {
            // Raw images are copied with an APFS clone, which is instant and shares blocks.
            try FileManager.default.copyItem(at: source, to: partial)
            progress(1)
        } else {
            guard let qemuImg = Self.locateQemuImg() else { throw DiskConverterError.qemuImgMissing }
            try await run(qemuImg, ["convert", "-p", "-f", format.rawValue, "-O", "raw", source.path, partial.path],
                          progress: progress)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Grows a raw image to `bytes`. The guest's partition and filesystem still need to be
    /// expanded from inside the guest afterwards.
    func resize(image: URL, to bytes: UInt64) async throws {
        guard let qemuImg = Self.locateQemuImg() else { throw DiskConverterError.qemuImgMissing }
        try await run(qemuImg, ["resize", "-f", "raw", image.path, String(bytes)], progress: nil)
    }

    private func run(_ executable: URL, _ arguments: [String],
                     progress: (@Sendable (Double) -> Void)?) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            output.append(text)
            // qemu-img -p prints "    (12.34/100%)\r"
            if let progress, let value = Self.lastProgressValue(in: text) {
                progress(value / 100)
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        if Task.isCancelled { throw DiskConverterError.cancelled }
        guard status == 0 else {
            let command = "qemu-img " + (arguments.first ?? "")
            throw DiskConverterError.processFailed(command: command, status: status, output: output.text)
        }
        progress?(1)
    }

    static func lastProgressValue(in text: String) -> Double? {
        let pattern = #"\((\d+(?:\.\d+)?)/100%\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[valueRange])
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        if buffer.count > 16_000 { buffer = String(buffer.suffix(8_000)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
