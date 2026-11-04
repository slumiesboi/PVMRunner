import SwiftUI
import Virtualization

/// Per-VM settings panel shown next to the library table.
struct VMDetailView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: VMController
    @State private var draft: VMRecord
    @State private var confirmDelete = false

    /// The saved record; changes made elsewhere (e.g. ejecting an ISO from the VM window) refresh the draft.
    let record: VMRecord

    init(record: VMRecord, controller: VMController) {
        self.record = record
        _draft = State(initialValue: record)
        self.controller = controller
    }

    private var locked: Bool { controller.state.isActive }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Hardware") {
                    Stepper(value: $draft.cpuCount, in: HostLimits.cpuRange) {
                        LabeledContent("CPUs", value: "\(draft.cpuCount)")
                    }
                    Stepper(value: $draft.memoryMB, in: HostLimits.memoryRangeMB, step: 512) {
                        LabeledContent("Memory", value: MemoryFormat.string(mb: draft.memoryMB))
                    }
                }

                Section("Network") {
                    NetworkSettingsView(mode: $draft.networkMode, interfaceID: $draft.bridgedInterfaceID)
                    LabeledContent("MAC address") {
                        HStack {
                            Text(draft.macAddress).monospaced().textSelection(.enabled)
                            Button {
                                draft.macAddress = VZMACAddress.randomLocallyAdministered().string
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderless)
                            .help("Generate a new random locally administered MAC address")
                        }
                    }
                }

                Section {
                    if let iso = draft.isoPath {
                        LabeledContent("ISO") {
                            HStack {
                                Text((iso as NSString).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(iso)
                                Button("Detach") { draft.isoPath = nil }
                            }
                        }
                    } else {
                        Button("Attach ISO…") {
                            if let url = OpenPanels.chooseISO() { draft.isoPath = url.path }
                        }
                    }
                } header: {
                    Text("Removable media")
                } footer: {
                    Text("The image is attached as a read-only USB mass storage device, for install or recovery media.")
                        .foregroundStyle(.secondary)
                }

                Section("Info") {
                    LabeledContent("Guest", value: "\(draft.guestOSDescription) (\(draft.guestOS.displayName), ARM64)")
                    LabeledContent("Disks", value: draft.diskFileNames.joined(separator: ", "))
                    LabeledContent("Imported from") {
                        Text(draft.sourcePVMPath).lineLimit(1).truncationMode(.middle).help(draft.sourcePVMPath)
                    }
                    Button("Show VM Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.directory(for: draft)])
                    }
                    .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .disabled(locked)
            .onChange(of: draft) { _, newValue in
                if newValue != record { library.update(newValue) }
            }
            .onChange(of: record) { _, newValue in
                if newValue != draft { draft = newValue }
            }

            if locked {
                Text("Stop the VM to change its settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .confirmationDialog("Move “\(draft.name)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { library.delete(id: draft.id) }
        } message: {
            Text("The converted disk images and settings are moved to the Trash. The original .pvm is not affected.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .disabled(locked)
                VMStateBadge(controller: controller)
                    .font(.callout)
            }
            Spacer()
            if controller.canStart {
                Button {
                    openWindow(id: WindowID.vm, value: draft.id)
                    Task { await library.start(id: draft.id) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Show Window") { openWindow(id: WindowID.vm, value: draft.id) }
            }
            Menu {
                Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                    .disabled(locked)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding()
    }
}

/// Network mode picker plus the per-mode bridging options.
struct NetworkSettingsView: View {
    @Binding var mode: NetworkMode
    @Binding var interfaceID: String?

    var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(NetworkMode.allCases) { Text($0.displayName).tag($0) }
        }
        switch mode {
        case .bridged: entitlementBridging
        case .socketVmnet: SocketVmnetSettingsView(interfaceID: $interfaceID)
        case .nat, .none: EmptyView()
        }
    }

    @ViewBuilder
    private var entitlementBridging: some View {
        let interfaces = VMConfigurationBuilder.bridgedInterfaces
        if !VMConfigurationBuilder.hasBridgedNetworkingEntitlement || interfaces.isEmpty {
            Label {
                Text("This build lacks the com.apple.vm.networking entitlement, which Apple must grant. "
                     + "The VM will fall back to NAT. Use “Bridged (socket_vmnet)” instead, or see the README.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            .font(.callout)
        } else {
            Picker("Interface", selection: Binding(
                get: { interfaceID ?? interfaces.first?.identifier ?? "" },
                set: { interfaceID = $0 })) {
                ForEach(interfaces, id: \.identifier) { interface in
                    Text("\(interface.localizedDisplayName ?? interface.identifier) (\(interface.identifier))")
                        .tag(interface.identifier)
                }
            }
        }
    }
}

/// Interface field, helper status and setup commands for socket_vmnet bridging.
struct SocketVmnetSettingsView: View {
    @Binding var interfaceID: String?
    @State private var isReachable = false

    private var interface: String { interfaceID?.isEmpty == false ? interfaceID! : "en0" }
    private var socketPath: String { SocketVmnetRelay.defaultSocketPath(interface: interface) }

    var body: some View {
        TextField("Host interface", text: Binding(get: { interface }, set: { interfaceID = $0 }),
                  prompt: Text("en0"))
            .onAppear(perform: refresh)
            .onChange(of: interface) { _, _ in refresh() }
        LabeledContent("Helper") {
            HStack(spacing: 6) {
                Circle().fill(isReachable ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(isReachable ? "Running" : "Not running")
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check again")
            }
        }
        .help(socketPath)
        if !isReachable {
            VStack(alignment: .leading, spacing: 6) {
                Text("Install socket_vmnet once, then start the bridged helper for \(interface) in Terminal "
                     + "(it keeps running across reboots):")
                    .font(.callout)
                CommandRow(command: "brew install socket_vmnet")
                CommandRow(command: "sudo bash \"\(SocketVmnetSetup.scriptPath)\" \(interface)")
                Text("Until then the VM falls back to NAT when it starts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() {
        isReachable = SocketVmnetRelay.isReachable(path: socketPath)
    }
}

/// Location of the helper install script shipped inside the app bundle.
enum SocketVmnetSetup {
    static var scriptPath: String {
        Bundle.main.path(forResource: "install-socket-vmnet-bridged", ofType: "sh")
            ?? "scripts/install-socket-vmnet-bridged.sh"
    }
}

struct CommandRow: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

enum MemoryFormat {
    static func string(mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024)
    }
}
