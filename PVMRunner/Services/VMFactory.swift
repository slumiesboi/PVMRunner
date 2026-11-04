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
}

/// Creates new, empty Linux VMs in the library.
struct VMFactory {
    var store = VMLibraryStore()

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
            let distro = PVMParser.linuxDistroNames.first(where: hint.contains)?.capitalized
            var record = VMRecord(
                id: UUID(), name: settings.name, guestOS: .linux, guestOSDescription: distro ?? "Linux",
                cpuCount: settings.cpuCount, memoryMB: settings.memoryMB, diskFileNames: [VMFiles.disk(0)],
                networkMode: settings.networkMode, bridgedInterfaceID: settings.bridgedInterfaceID,
                macAddress: VZMACAddress.randomLocallyAdministered().string,
                isoPath: settings.isoURL.path, displayWidth: 1920, displayHeight: 1200,
                sourcePVMPath: settings.isoURL.path, importedAt: Date())
            record.directoryName = folder
            try store.save(record)
            return record
        } catch {
            store.removeDirectory(named: folder)
            throw error
        }
    }
}
