import Foundation

/// Reads and writes VM directories under `~/Library/Application Support/PVMRunner/VMs/`.
struct VMLibraryStore {
    private let fileManager = FileManager.default

    var rootURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PVMRunner/VMs", isDirectory: true)
    }

    func directory(for record: VMRecord) -> URL {
        rootURL.appendingPathComponent(record.directoryName, isDirectory: true)
    }

    func loadAll() -> [VMRecord] {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let folders = (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder -> VMRecord? in
            let url = folder.appendingPathComponent(VMFiles.record)
            guard let data = try? Data(contentsOf: url),
                  var record = try? decoder.decode(VMRecord.self, from: data) else { return nil }
            record.directoryName = folder.lastPathComponent
            return record
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ record: VMRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: directory(for: record).appendingPathComponent(VMFiles.record), options: .atomic)
    }

    /// Creates a new, uniquely named folder for a VM and returns its name.
    func makeDirectory(forVMNamed name: String) throws -> String {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let base = name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "VM" : base
        var candidate = safeBase
        var suffix = 2
        while fileManager.fileExists(atPath: rootURL.appendingPathComponent(candidate).path) {
            candidate = "\(safeBase) \(suffix)"
            suffix += 1
        }
        try fileManager.createDirectory(at: rootURL.appendingPathComponent(candidate), withIntermediateDirectories: false)
        return candidate
    }

    /// Moves a VM folder to the Trash (recoverable) rather than deleting it outright.
    func moveToTrash(_ record: VMRecord) throws {
        try fileManager.trashItem(at: directory(for: record), resultingItemURL: nil)
    }

    func removeDirectory(named name: String) {
        try? fileManager.removeItem(at: rootURL.appendingPathComponent(name))
    }

    /// Logical (virtual) size of all disks in bytes.
    func diskSize(of record: VMRecord) -> UInt64 {
        record.diskFileNames.reduce(0) { total, name in
            let url = directory(for: record).appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + UInt64(size)
        }
    }

    /// Bytes actually allocated on disk (raw images are sparse).
    func allocatedSize(of record: VMRecord) -> UInt64 {
        record.diskFileNames.reduce(0) { total, name in
            let url = directory(for: record).appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            return total + UInt64(size)
        }
    }
}
