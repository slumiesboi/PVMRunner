import SwiftUI
import Virtualization

/// The VM's display window with run controls in the toolbar.
struct VMWindowView: View {
    @EnvironmentObject private var library: LibraryViewModel
    let vmID: UUID

    var body: some View {
        if let record = library.record(id: vmID) {
            VMWindowContent(record: record, controller: library.controller(for: vmID))
        } else {
            Text("This virtual machine no longer exists.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}

private struct VMWindowContent: View {
    @EnvironmentObject private var library: LibraryViewModel
    let record: VMRecord
    @ObservedObject var controller: VMController
    @State private var confirmForceStop = false

    var body: some View {
        VStack(spacing: 0) {
            if !controller.notices.isEmpty {
                NoticeBanner(notices: controller.notices) { controller.notices = [] }
            }
            ZStack {
                Color.black
                if let vm = controller.virtualMachine {
                    VMDisplayView(virtualMachine: vm)
                }
                if controller.virtualMachine == nil || controller.state == .starting {
                    placeholder
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(record.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .alert("Virtual machine error", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .confirmationDialog("Force stop “\(record.name)”?", isPresented: $confirmForceStop) {
            Button("Force Stop", role: .destructive) { Task { await controller.forceStop() } }
        } message: {
            Text("This powers off the VM immediately. Unsaved data in the guest will be lost.")
        }
    }

    private var subtitle: String {
        var parts = [controller.state.displayName]
        if let mode = controller.effectiveNetworkMode { parts.append(mode.displayName) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 12) {
            switch controller.state {
            case .starting:
                ProgressView().controlSize(.large)
                Text("Starting…").foregroundStyle(.white)
            case .error:
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.yellow)
                Text("The VM is not running.").foregroundStyle(.white)
                startButton
            default:
                Image(systemName: "power").font(.system(size: 40)).foregroundStyle(.gray)
                Text("\(record.name) is powered off").foregroundStyle(.white)
                startButton
            }
        }
    }

    private var startButton: some View {
        Button {
            Task { await library.start(id: record.id) }
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VMStateBadge(controller: controller)
                .padding(.horizontal, 6)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await library.start(id: record.id) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(!controller.canStart)
            .help("Start")

            if controller.canResume {
                Button {
                    Task { await controller.resume() }
                } label: {
                    Label("Resume", systemImage: "playpause.fill")
                }
                .help("Resume")
            } else {
                Button {
                    Task { await controller.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(!controller.canPause)
                .help("Pause")
            }

            Button {
                controller.requestStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!controller.canRequestStop)
            .help("Ask the guest to shut down")

            Button {
                confirmForceStop = true
            } label: {
                Label("Force Stop", systemImage: "power")
            }
            .disabled(!controller.canForceStop)
            .help("Power off immediately")
        }
    }
}

private struct NoticeBanner: View {
    let notices: [String]
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notices, id: \.self) { Text($0).font(.callout) }
            }
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.15))
    }
}

/// Hosts a `VZVirtualMachineView`. The guest display follows the window size.
struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
    }
}
