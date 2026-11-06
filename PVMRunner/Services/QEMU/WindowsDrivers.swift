import Foundation

/// The virtio-win driver ISO (Fedora's signed Windows drivers for QEMU's virtio devices,
/// including ARM64 builds). Windows has no in-box driver for the virtual network card, so
/// PVMRunner downloads the ISO once on request and attaches it to every Windows VM as a
/// second drive.
@MainActor
final class WindowsDrivers: NSObject, ObservableObject {
    static let shared = WindowsDrivers()
    static let downloadURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!

    /// PowerShell (as administrator) command that installs the ARM64 drivers from the driver
    /// drive, whatever letter Windows gave it. New VMs run it at the first sign-in.
    nonisolated static let installCommand = #"$d = (Get-Volume | ? FileSystemLabel -like 'virtio-win*').DriveLetter; Get-ChildItem "${d}:\*\w11\ARM64\*.inf" | % { pnputil /add-driver $_.FullName /install }"#

    @Published private(set) var progress: Double?
    @Published var errorMessage: String?
    @Published private(set) var isAvailable = false

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    nonisolated static var isoURL: URL {
        VMLibraryStore().rootURL.deletingLastPathComponent()
            .appendingPathComponent("Drivers/virtio-win.iso")
    }

    /// Path of the downloaded ISO, if present.
    nonisolated static var installedISO: URL? {
        FileManager.default.fileExists(atPath: isoURL.path) ? isoURL : nil
    }

    override init() {
        super.init()
        isAvailable = Self.installedISO != nil
    }

    func download() {
        guard task == nil else { return }
        errorMessage = nil
        progress = 0
        let task = URLSession.shared.downloadTask(with: Self.downloadURL) { [weak self] location, response, error in
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "The server returned HTTP \(http.statusCode)."
            } else if let location {
                do {
                    let target = Self.isoURL
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: location, to: target)
                } catch {
                    failure = error.localizedDescription
                }
            }
            Task { @MainActor in self?.finish(error: failure) }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in if self?.task != nil { self?.progress = fraction } }
        }
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(error: String?) {
        task = nil
        observation = nil
        progress = nil
        if let error, !error.contains("cancelled") {
            errorMessage = "The driver download failed: \(error)"
        }
        isAvailable = Self.installedISO != nil
    }
}
