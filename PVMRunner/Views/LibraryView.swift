import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var importer: ImportViewModel
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            vmTable
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            Group {
                if let id = library.selection, let record = library.record(id: id) {
                    VMDetailView(record: record, controller: library.controller(for: id))
                        .id(id)
                } else {
                    Text("Select a virtual machine")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 340, idealWidth: 380, maxHeight: .infinity)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.presentNewVM()
                } label: {
                    Label("New VM", systemImage: "plus")
                }
                .help("Create a VM and install an OS from an ISO (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let url = OpenPanels.choosePVM() { importer.open(url) }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a Parallels .pvm or a QCOW2, VMDK, VDI, VHD(X) or raw disk image (⌘O)")
            }
        }
        .sheet(isPresented: Binding(get: { importer.isPresented }, set: { if !$0 { importer.dismiss() } })) {
            ImportSheet()
        }
        .sheet(isPresented: $library.isNewVMPresented) {
            NewVMSheet(iso: library.newVMISO)
        }
        .alert("PVMRunner", isPresented: Binding(get: { library.errorMessage != nil },
                                                 set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var vmTable: some View {
        if library.records.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No virtual machines yet")
                    .font(.title3)
                Text("Drop a Parallels .pvm, a disk image (.qcow2, .vmdk, .vdi, .vhdx, .img) or an installer ISO here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Import…") {
                        if let url = OpenPanels.choosePVM() { importer.open(url) }
                    }
                    Button("New VM from ISO…") { library.presentNewVM() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(library.records, selection: $library.selection) {
                TableColumn("Name") { record in
                    Label(record.name, systemImage: record.guestOS.symbolName)
                }
                TableColumn("OS") { record in
                    Text(record.guestOSDescription)
                }
                .width(min: 70, ideal: 90)
                TableColumn("State") { record in
                    VMStateBadge(controller: library.controller(for: record.id))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Disk") { record in
                    DiskSizeText(sizes: library.diskSizes[record.id])
                }
                .width(min: 90, ideal: 130)
            }
            .contextMenu(forSelectionType: VMRecord.ID.self) { ids in
                if let id = ids.first {
                    Button("Show in Finder") {
                        if let record = library.record(id: id) {
                            NSWorkspace.shared.activateFileViewerSelecting([library.directory(for: record)])
                        }
                    }
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                if url.pathExtension.lowercased() == "iso" {
                    library.presentNewVM(iso: url)
                } else {
                    importer.open(url)
                }
            }
        }
        return true
    }
}

struct VMStateBadge: View {
    @ObservedObject var controller: VMController

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(controller.state.displayName)
        }
    }

    private var color: Color {
        switch controller.state {
        case .running: return .green
        case .paused: return .yellow
        case .error: return .red
        case .stopped: return .secondary
        default: return .orange
        }
    }
}

struct DiskSizeText: View {
    var sizes: (logical: UInt64, allocated: UInt64)?

    var body: some View {
        if let sizes {
            Text("\(Self.format(sizes.allocated)) of \(Self.format(sizes.logical))")
                .help("Space used on disk of the disk's full size (raw images are sparse)")
        } else {
            Text("—")
        }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
