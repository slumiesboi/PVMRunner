import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var records: [VMRecord] = []
    @Published var selection: VMRecord.ID?
    @Published var errorMessage: String?
    @Published private(set) var diskSizes: [UUID: (logical: UInt64, allocated: UInt64)] = [:]

    let store = VMLibraryStore()
    private var controllers: [UUID: VMController] = [:]

    init() {
        reload()
    }

    func reload() {
        records = store.loadAll()
        diskSizes = Dictionary(uniqueKeysWithValues: records.map {
            ($0.id, (store.diskSize(of: $0), store.allocatedSize(of: $0)))
        })
        if let selection, !records.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    func record(id: UUID) -> VMRecord? {
        records.first { $0.id == id }
    }

    func controller(for id: UUID) -> VMController {
        if let existing = controllers[id] { return existing }
        let controller = VMController(vmID: id)
        controllers[id] = controller
        return controller
    }

    var hasActiveVMs: Bool {
        controllers.values.contains { $0.state.isActive }
    }

    func update(_ record: VMRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        do {
            try store.save(record)
        } catch {
            errorMessage = "Could not save settings for “\(record.name)”: \(error.localizedDescription)"
        }
    }

    func didImport(_ record: VMRecord) {
        reload()
        selection = record.id
    }

    func start(id: UUID) async {
        guard let record = record(id: id) else { return }
        await controller(for: id).start(record: record, directory: store.directory(for: record))
    }

    func delete(id: UUID) {
        guard let record = record(id: id) else { return }
        if controllers[id]?.state.isActive == true {
            errorMessage = "Stop “\(record.name)” before deleting it."
            return
        }
        do {
            try store.moveToTrash(record)
            controllers[id] = nil
            reload()
        } catch {
            errorMessage = "Could not move “\(record.name)” to the Trash: \(error.localizedDescription)"
        }
    }

    func directory(for record: VMRecord) -> URL {
        store.directory(for: record)
    }
}
