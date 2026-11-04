import SwiftUI

/// Creates an empty Linux VM and boots it from an installer ISO.
struct NewVMSheet: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var isoURL: URL?
    @State private var name = ""
    @State private var diskSizeGB = 64
    @State private var cpuCount = HostLimits.clampCPU(4)
    @State private var memoryMB = HostLimits.clampMemoryMB(8192)
    @State private var networkMode: NetworkMode = .nat
    @State private var bridgedInterfaceID: String?
    @State private var probe: ArchitectureProbe.Result?
    @State private var errorMessage: String?

    init(iso: URL?) {
        _isoURL = State(initialValue: iso)
        _name = State(initialValue: iso.map(Self.suggestedName) ?? "")
    }

    private var isX86Only: Bool { probe?.architecture == .x86 }
    private var canCreate: Bool {
        isoURL != nil && !isX86Only && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("New Virtual Machine").font(.title2.weight(.semibold))
                    Text("Install an operating system from an ISO").foregroundStyle(.secondary)
                }
            }
            .padding()

            Form {
                Section {
                    LabeledContent("ISO") {
                        HStack {
                            Text(isoURL?.lastPathComponent ?? "None")
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(isoURL == nil ? .secondary : .primary)
                                .help(isoURL?.path ?? "")
                            Button("Choose…") {
                                if let url = OpenPanels.chooseISO() { select(url) }
                            }
                        }
                    }
                    if let probe {
                        Label {
                            Text(probe.evidence)
                        } icon: {
                            switch probe.architecture {
                            case .arm64: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .x86: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                            }
                        }
                        .font(.callout)
                        if isX86Only {
                            Text("This installer is for Intel/AMD PCs and cannot boot on Apple Silicon. "
                                 + "Download the ARM64 (aarch64) edition instead.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if probe.architecture == .unknown {
                            Text("It may still boot, but make sure this is an ARM64 (aarch64) UEFI installer.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Install media")
                } footer: {
                    Text("Use an ARM64 (aarch64) installer, such as Ubuntu Server/Desktop for ARM, Fedora aarch64 or Debian arm64.")
                        .foregroundStyle(.secondary)
                }

                Section("Virtual machine") {
                    TextField("Name", text: $name)
                    Stepper(value: $cpuCount, in: HostLimits.cpuRange) {
                        LabeledContent("CPUs", value: "\(cpuCount)")
                    }
                    Stepper(value: $memoryMB, in: HostLimits.memoryRangeMB, step: 512) {
                        LabeledContent("Memory", value: MemoryFormat.string(mb: memoryMB))
                    }
                    Stepper(value: $diskSizeGB, in: 8...2048, step: 8) {
                        LabeledContent("Disk", value: "\(diskSizeGB) GB")
                    }
                    Text("The disk is sparse: it only uses space on your Mac as the guest writes data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Network") {
                    NetworkSettingsView(mode: $networkMode, interfaceID: $bridgedInterfaceID)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300, idealHeight: 520)

            HStack {
                Text("When the installer finishes, eject the ISO from the VM window's toolbar.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create and Start") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 560)
        .task(id: isoURL) { await runProbe() }
    }

    private func select(_ url: URL) {
        let previousSuggestion = isoURL.map(Self.suggestedName)
        isoURL = url
        if name.isEmpty || name == previousSuggestion { name = Self.suggestedName(url) }
    }

    private func runProbe() async {
        probe = nil
        guard let isoURL else { return }
        probe = await Task.detached(priority: .userInitiated) { ArchitectureProbe.probeInstallMedia(isoURL) }.value
    }

    private func create() {
        guard let isoURL else { return }
        let settings = NewVMSettings(
            name: name.trimmingCharacters(in: .whitespaces), isoURL: isoURL, diskSizeGB: diskSizeGB,
            cpuCount: cpuCount, memoryMB: memoryMB, networkMode: networkMode,
            bridgedInterfaceID: bridgedInterfaceID)
        do {
            let record = try VMFactory().createFromISO(settings)
            library.didImport(record)
            dismiss()
            openWindow(id: WindowID.vm, value: record.id)
            Task { await library.start(id: record.id) }
        } catch {
            errorMessage = "Could not create the VM: \(error.localizedDescription)"
        }
    }

    /// "ubuntu-24.04.3-live-server-arm64.iso" → "ubuntu-24.04.3-live-server-arm64".
    static func suggestedName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
