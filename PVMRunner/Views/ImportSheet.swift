import SwiftUI

/// Summary shown before import, then conversion progress, or an error.
struct ImportSheet: View {
    @EnvironmentObject private var importer: ImportViewModel
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        Group {
            switch importer.phase {
            case .idle:
                EmptyView()
            case .summary:
                if let parsed = importer.parsed {
                    summary(parsed)
                }
            case .converting:
                converting
            case .failed(let message, let suggestion):
                failure(message: message, suggestion: suggestion)
            }
        }
        .frame(width: 560)
    }

    // MARK: Summary

    private func summary(_ parsed: ParsedPVM) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: parsed.guestOS == .macOS ? "apple.logo" : "shippingbox.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Import Virtual Machine").font(.title2.weight(.semibold))
                    Text(parsed.bundleURL.lastPathComponent).foregroundStyle(.secondary)
                }
            }
            .padding()

            Form {
                if let reason = parsed.unsupportedReason {
                    Section {
                        Label {
                            Text(reason)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    } header: {
                        Text("Cannot import")
                    }
                }

                Section("Guest") {
                    TextField("Name", text: $importer.name)
                    LabeledContent("Operating system", value: parsed.guestOSDescription == parsed.guestOS.displayName
                                   ? parsed.guestOS.displayName
                                   : "\(parsed.guestOSDescription) (\(parsed.guestOS.displayName))")
                    LabeledContent("Architecture") {
                        Text(parsed.architecture.displayName)
                            .help(parsed.architectureEvidence.joined(separator: "\n"))
                    }
                    if parsed.architecture == .unknown {
                        Text(parsed.architectureEvidence.joined(separator: ". "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if parsed.unsupportedReason == nil {
                    Section("Hardware") {
                        Stepper(value: $importer.cpuCount, in: HostLimits.cpuRange) {
                            LabeledContent("CPUs", value: "\(importer.cpuCount)")
                        }
                        Stepper(value: $importer.memoryMB, in: HostLimits.memoryRangeMB, step: 512) {
                            LabeledContent("Memory", value: MemoryFormat.string(mb: importer.memoryMB))
                        }
                        if parsed.origin == .parallels
                            && (parsed.cpuCount != importer.cpuCount || parsed.memoryMB != importer.memoryMB) {
                            Text("Parallels config: \(parsed.cpuCount) CPUs, \(MemoryFormat.string(mb: parsed.memoryMB))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Disks") {
                    if parsed.disks.isEmpty {
                        Text("No importable disks").foregroundStyle(.secondary)
                    }
                    ForEach(parsed.disks) { disk in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(disk.displayName) {
                                Text(disk.virtualSize.map { DiskSizeText.format($0) } ?? "Unknown size")
                            }
                            Text("\(disk.format.displayName) → raw")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(disk.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                    if parsed.unsupportedReason == nil && !parsed.disks.isEmpty {
                        Toggle("Resize boot disk", isOn: $importer.resizeEnabled)
                        if importer.resizeEnabled {
                            Stepper(value: $importer.resizeGB, in: importer.bootDiskGB...4096, step: 8) {
                                LabeledContent("New size", value: "\(importer.resizeGB) GB")
                            }
                            Text("Grow the partition and filesystem inside the guest afterwards (e.g. growpart + resize2fs).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if parsed.unsupportedReason == nil {
                    Section("Network") {
                        NetworkSettingsView(mode: $importer.networkMode, interfaceID: $importer.bridgedInterfaceID)
                        LabeledContent("MAC address") {
                            if let mac = parsed.preferredMACAddress {
                                Text(mac).monospaced()
                            } else {
                                Text(parsed.origin == .parallels ? "Random (none valid in config)" : "Random")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !parsed.warnings.isEmpty {
                    Section("Notes") {
                        ForEach(parsed.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle").font(.callout)
                        }
                    }
                }

                if parsed.unsupportedReason == nil && importer.qemuImgMissing {
                    Section {
                        QemuMissingView()
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300, idealHeight: 520)

            HStack {
                Text(parsed.origin == .parallels ? "The original .pvm is never modified." : "The original image is never modified.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { importer.dismiss() }
                    .keyboardShortcut(.cancelAction)
                if parsed.unsupportedReason == nil {
                    Button("Import") {
                        importer.confirm { library.didImport($0) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importer.qemuImgMissing)
                }
            }
            .padding()
        }
    }

    // MARK: Progress

    private var converting: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Importing “\(importer.name)”").font(.title3.weight(.semibold))
            ProgressView(value: importer.progress) {
                Text(importer.progressMessage)
            } currentValueLabel: {
                Text(importer.progress, format: .percent.precision(.fractionLength(0)))
            }
            HStack {
                Text("Converted VMs are stored in ~/Library/Application Support/PVMRunner/VMs.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { importer.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }

    // MARK: Failure

    private func failure(message: String, suggestion: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text(message).textSelection(.enabled)
            if let suggestion {
                Text(suggestion)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("OK") { importer.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

struct QemuMissingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("qemu-img is required to convert this disk", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            Text("It was not found at /opt/homebrew/bin/qemu-img or /usr/local/bin/qemu-img. Install QEMU with Homebrew in Terminal:")
            HStack {
                Text("brew install qemu").font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install qemu", forType: .string)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Then click Cancel and open the file again.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
