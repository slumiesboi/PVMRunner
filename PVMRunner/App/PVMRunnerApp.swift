import AppKit
import SwiftUI

@main
struct PVMRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryViewModel()
    @StateObject private var importer = ImportViewModel()

    var body: some Scene {
        Window("PVMRunner", id: WindowID.library) {
            LibraryView()
                .environmentObject(library)
                .environmentObject(importer)
                .onAppear { appDelegate.library = library }
        }
        .defaultSize(width: 1000, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PVM…") {
                    if let url = OpenPanels.choosePVM() { importer.open(url) }
                }
                .keyboardShortcut("o")
            }
        }

        WindowGroup("Virtual Machine", id: WindowID.vm, for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmID: vmID)
                    .environmentObject(library)
            }
        }
        .defaultSize(width: 1280, height: 840)
    }
}

enum WindowID {
    static let library = "library"
    static let vm = "vm"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActive = MainActor.assumeIsolated { library?.hasActiveVMs ?? false }
        guard hasActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Virtual machines are still running"
        alert.informativeText = "Quitting PVMRunner powers them off immediately, which can lose unsaved data in the guest. Shut them down from inside the guest or with Stop first."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
enum OpenPanels {
    /// .pvm bundles are only treated as packages when the system knows the type, so the
    /// panel allows choosing folders and validates the extension on confirmation.
    static func choosePVM() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Parallels Virtual Machine"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        let parallelsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Parallels")
        if FileManager.default.fileExists(atPath: parallelsFolder.path) {
            panel.directoryURL = parallelsFolder
        }
        let delegate = PVMPanelDelegate()
        panel.delegate = delegate
        return withExtendedLifetime(delegate) {
            panel.runModal() == .OK ? panel.url : nil
        }
    }

    static func chooseISO() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Attach ISO or Disk Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.diskImage, .init(filenameExtension: "iso") ?? .data, .init(filenameExtension: "img") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private final class PVMPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard ImportViewModel.isImportable(url) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is not a .pvm bundle.",
                NSLocalizedRecoverySuggestionErrorKey: "Select a Parallels virtual machine (.pvm).",
            ])
        }
    }
}
