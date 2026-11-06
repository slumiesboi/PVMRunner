import Foundation
import Virtualization

/// Settings for a VM created from scratch to install an OS from an ISO.
struct NewVMSettings {
    var name: String
    var isoURL: URL
    var diskSizeGB: Int
    var cpuCount: Int
    var memoryMB: Int
    var networkMode: NetworkMode
    var bridgedInterfaceID: String?
    var guestOS: GuestOS = .linux
}

/// Creates new, empty Linux or Windows VMs in the library.
struct VMFactory {
    var store = VMLibraryStore()
    /// The virtio-win ISO. When present, Windows Setup installs the virtio storage driver, so a
    /// new Windows VM uses the faster virtio disk from the start.
    var windowsDriversISO = WindowsDrivers.installedISO

    /// Creates the VM folder with a sparse blank disk and the ISO attached. With an empty
    /// disk and a fresh EFI variable store the firmware boots the installer from the ISO.
    func createFromISO(_ settings: NewVMSettings) throws -> VMRecord {
        let folder = try store.makeDirectory(forVMNamed: settings.name)
        do {
            let directory = store.rootURL.appendingPathComponent(folder)
            let disk = directory.appendingPathComponent(VMFiles.disk(0))
            guard FileManager.default.createFile(atPath: disk.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: disk.path])
            }
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: UInt64(settings.diskSizeGB) * 1_073_741_824)
            try handle.close()

            let hint = settings.isoURL.lastPathComponent.lowercased()
            let description: String
            if settings.guestOS == .windows {
                description = hint.contains("win10") || hint.contains("windows10") ? "Windows 10" : "Windows 11"
                try QEMUCommandBuilder.ensureVariableStore(at: directory.appendingPathComponent(VMFiles.qemuVariableStore))
            } else {
                description = PVMParser.linuxDistroNames.first(where: hint.contains)?.capitalized ?? "Linux"
            }
            var record = VMRecord(
                id: UUID(), name: settings.name, guestOS: settings.guestOS, guestOSDescription: description,
                cpuCount: settings.cpuCount, memoryMB: settings.memoryMB, diskFileNames: [VMFiles.disk(0)],
                networkMode: settings.networkMode, bridgedInterfaceID: settings.bridgedInterfaceID,
                macAddress: VZMACAddress.randomLocallyAdministered().string,
                isoPath: settings.isoURL.path, displayWidth: 1920, displayHeight: 1200,
                sourcePVMPath: settings.isoURL.path, importedAt: Date())
            record.directoryName = folder
            if settings.guestOS == .windows && windowsDriversISO != nil {
                record.diskBus = .virtio
            }
            try store.save(record)
            return record
        } catch {
            store.removeDirectory(named: folder)
            throw error
        }
    }
}
