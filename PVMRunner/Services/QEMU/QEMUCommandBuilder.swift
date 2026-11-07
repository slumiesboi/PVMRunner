import Foundation

/// Builds the `qemu-system-aarch64` command line for a Windows VM.
///
/// Devices are ones Windows 11 on ARM drives with its own in-box drivers: an NVMe boot disk
/// (or virtio once the virtio-win storage driver is in, see `QEMUDiskBus`),
/// a ramfb framebuffer (or virtio-gpu once the display driver is in, see `QEMUDisplay`),
/// USB keyboard and tablet on an XHCI controller, a TPM 2.0 (swtpm) and the install ISO as a
/// USB drive. HVF runs the guest at native speed.
enum QEMUCommandBuilder {
    struct Output {
        var arguments: [String]
        var effectiveNetworkMode: NetworkMode
        var notices: [String]
        var isoAttached: Bool
        /// The screens on the VNC sockets: ramfb, virtio-gpu, or ramfb on `vnc` and virtio-gpu on `gpuVNC`.
        var screens: Screens
    }

    enum Screens { case ramfb, gpu, both }

    /// Sockets live in a short per-run directory: Unix socket paths are limited to 104 bytes,
    /// which the VM folder under Application Support can exceed.
    struct RunPaths {
        var directory: URL
        var qmp: String { directory.appendingPathComponent("qmp.sock").path }
        var vnc: String { directory.appendingPathComponent("vnc.sock").path }
        /// virtio-gpu's screen while ramfb is attached too.
        var gpuVNC: String { directory.appendingPathComponent("vnc-gpu.sock").path }
        var tpm: String { directory.appendingPathComponent("tpm.sock").path }
        /// Symlink to the VM's TPM state folder: swtpm splits options on commas and can't escape them.
        var tpmState: String { directory.appendingPathComponent("tpmstate").path }
    }

    static func build(record: VMRecord, directory: URL, run: RunPaths, tools: QEMUTools) throws -> Output {
        var notices: [String] = []
        let vars = directory.appendingPathComponent(VMFiles.qemuVariableStore)
        try ensureVariableStore(at: vars)

        var args = [
            "-name", escape(record.name),
            "-machine", "virt,highmem=on",
            "-accel", "hvf",
            "-cpu", "host",
            "-smp", "\(HostLimits.clampCPU(record.cpuCount))",
            "-m", "\(HostLimits.clampMemoryMB(record.memoryMB))",
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(escape(tools.firmware.path))",
            "-drive", "if=pflash,format=raw,unit=1,file=\(escape(vars.path))",
            // 8 USB 2 and 8 USB 3 ports: with the default 4, extra drives land on a 12 Mb/s hub.
            "-device", "qemu-xhci,id=xhci,p2=8,p3=8",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            // tpm-tis-device's PPI region isn't 16 KB page aligned, which HVF rejects.
            "-chardev", "socket,id=chrtpm,path=\(escape(run.tpm))",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off",
            "-qmp", "unix:\(escape(run.qmp)),server=on,wait=off",
            "-display", "none",
            "-rtc", "base=localtime",
        ]

        let bus = record.diskBus ?? .nvme
        if bus != .nvme {
            // virtio-blk requests are handled on their own thread instead of QEMU's main loop.
            args += ["-object", "iothread,id=io0"]
        }
        for (index, name) in record.diskFileNames.enumerated() {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw VMConfigurationError.missingDisk(name) }
            let device = bus == .virtio ? "virtio-blk-pci,id=vdisk\(index),drive=disk\(index),iothread=io0" : "nvme,drive=disk\(index)"
            args += ["-drive", "if=none,id=disk\(index),format=raw,discard=unmap,file=\(escape(url.path))",
                     "-device", "\(device),serial=PVM\(String(format: "%04d", index + 1)),bootindex=\(index + 1)"]
        }
        // A small spare disk on the other controller keeps that controller's driver loading at
        // boot: Windows stops boot-loading storage drivers no disk uses, so after booting from
        // virtio alone it could no longer boot from NVMe, and vice versa.
        let probe = directory.appendingPathComponent(VMFiles.virtioProbe)
        if bus == .nvme {
            try? FileManager.default.removeItem(at: probe)
        } else {
            if !FileManager.default.fileExists(atPath: probe.path) {
                FileManager.default.createFile(atPath: probe.path, contents: nil)
                let handle = try FileHandle(forWritingTo: probe)
                try handle.truncate(atOffset: 16 * 1024 * 1024)
                try handle.close()
            }
            args += ["-drive", "if=none,id=probe,format=raw,file=\(escape(probe.path))"]
            if bus == .preparingVirtio {
                // Windows installs the virtio storage driver for this disk; the firmware leaves it
                // alone because it isn't in the boot order. QEMUMachine watches it to see the driver load.
                args += ["-device", "virtio-blk-pci,id=\(virtioProbeDevice),drive=probe,iothread=io0"]
            } else {
                args += ["-device", "nvme,id=nvmeprobe,drive=probe,serial=PVMSPARE"]
            }
        }

        var isoAttached = false
        if let isoPath = record.isoPath, !isoPath.isEmpty {
            if FileManager.default.fileExists(atPath: isoPath) {
                args += ["-drive", "if=none,id=cd0,media=cdrom,readonly=on,file=\(escape(isoPath))",
                         "-device", "usb-storage,id=\(QEMUMachine.bootMediaDevice),drive=cd0,removable=on,bootindex=0"]
                isoAttached = true
                // Windows Setup reads autounattend.xml and $WinPEDriver$ from the root of removable drives.
                let setup = try WindowsSetupFiles.write(in: directory)
                if let drivers = WindowsDrivers.installedISO {
                    do {
                        try WindowsSetupFiles.addDrivers(in: setup, from: drivers)
                    } catch {
                        notices.append(error.localizedDescription)
                    }
                }
                args += ["-drive", "if=none,id=setup,format=raw,readonly=on,file=fat:\(escape(setup.path))",
                         "-device", "usb-storage,drive=setup,removable=on"]
            } else {
                notices.append("The attached ISO “\((isoPath as NSString).lastPathComponent)” no longer exists and was skipped.")
            }
        }

        if let drivers = WindowsDrivers.installedISO {
            args += ["-drive", "if=none,id=drivers,media=cdrom,readonly=on,file=\(escape(drivers.path))",
                     "-device", "usb-storage,drive=drivers,removable=on"]
        }

        let display = record.display ?? .basic
        let screens: Screens = display == .basic ? .ramfb : display == .virtio && !isoAttached ? .gpu : .both
        if screens != .gpu {
            args += ["-device", "ramfb,id=fb"]
        }
        if screens != .ramfb {
            let width = max(640, min(record.displayWidth, 5120)), height = max(480, min(record.displayHeight, 2880))
            // xres/yres become the preferred mode Windows starts in; its own resolution menu
            // isn't available with this driver.
            args += ["-device", "\(gpuDevice),id=gpu,xres=\(width),yres=\(height)"]
        }
        if screens == .both {
            args += ["-vnc", "unix:\(escape(run.vnc)),display=fb", "-vnc", "unix:\(escape(run.gpuVNC)),id=gpuvnc,display=gpu"]
        } else {
            args += ["-vnc", "unix:\(escape(run.vnc))"]
        }

        var mode = record.networkMode
        switch mode {
        case .nat:
            args += ["-netdev", "user,id=net0"]
        case .socketVmnet:
            let path = record.effectiveSocketVmnetPath
            if SocketVmnetRelay.isReachable(path: path) {
                // QEMU speaks socket_vmnet's length-prefixed stream protocol natively.
                args += ["-netdev", "stream,id=net0,server=off,addr.type=unix,addr.path=\(escape(path))"]
            } else {
                notices.append("The socket_vmnet helper is not running at \(path), so the VM uses NAT instead.")
                args += ["-netdev", "user,id=net0"]
                mode = .nat
            }
        case .bridged:
            notices.append("Windows VMs can't use entitlement bridging; using NAT. Choose “Bridged (socket_vmnet)” to bridge.")
            args += ["-netdev", "user,id=net0"]
            mode = .nat
        case .none:
            break
        }
        if mode != .none {
            args += ["-device", "\(networkDevice),netdev=net0,mac=\(record.macAddress)"]
        }

        return Output(arguments: args, effectiveNetworkMode: mode, notices: notices, isoAttached: isoAttached, screens: screens)
    }

    /// The NIC model. Windows has no in-box virtio driver: first-run setup continues offline
    /// (see `WindowsSetupFiles`) and the driver comes from the virtio-win ISO (`WindowsDrivers`).
    static let networkDevice = "virtio-net-pci"

    static let gpuDevice = "virtio-gpu-pci"

    /// QEMU id of the spare disk while it is on virtio, preparing the switch to virtio.
    static let virtioProbeDevice = "virtioprobe"

    /// QEMU option values separate on commas; a literal comma is written twice.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }

    static func ensureVariableStore(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try QEMUVariableStore.create(at: url)
    }
}

/// The files Windows Setup picks up from a removable drive.
///
/// The answer file clears the Secure Boot check (Homebrew's ARM firmware has no Secure Boot,
/// which Windows 11 Setup otherwise requires) and lets first-run setup continue without
/// internet. At the first sign-in it installs the ARM64 virtio drivers from the driver drive,
/// which brings up networking. Everything else in Setup stays interactive.
///
/// With the virtio-win ISO downloaded, the virtio storage and display drivers also go in
/// `$WinPEDriver$`: Setup loads them and installs them into the new system, so a new VM can
/// use the faster virtio disk and virtio-gpu from the start.
enum WindowsSetupFiles {
    static let driverFolder = "$WinPEDriver$"

    static func write(in directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(VMFiles.windowsSetup)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try autounattend.write(to: folder.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Drivers Setup loads from `$WinPEDriver$` and installs into the new system: storage, so a
    /// virtio disk is visible, and display, so the installed system can use virtio-gpu.
    static let setupDrivers = ["viostor", "viogpudo"]

    /// Copies the Windows 11 ARM64 builds (without debug symbols) of `setupDrivers` out of the
    /// driver ISO into `$WinPEDriver$`, once each. The ISO stores those files as hard links to
    /// another folder's copies, so tar extracts every ARM64 build and the w11 one is kept.
    static func addDrivers(in setup: URL, from iso: URL) throws {
        let destination = setup.appendingPathComponent(driverFolder)
        let missing = setupDrivers.filter {
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
        }
        guard !missing.isEmpty else { return }
        let staging = setup.deletingLastPathComponent().appendingPathComponent(".drivers-partial")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let extracted = try run("/usr/bin/tar", ["-xf", iso.path, "-C", staging.path, "--exclude", "*.pdb"]
                                + missing.map { "\($0)/*/ARM64" })
        // Files keep the ISO's read-only modes, which would stop them from being cleaned up.
        _ = try run("/bin/chmod", ["-R", "u+w", staging.path])
        guard extracted else { throw WindowsDriversError.extractFailed }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for driver in missing {
            let build = staging.appendingPathComponent("\(driver)/w11/ARM64")
            guard FileManager.default.fileExists(atPath: build.appendingPathComponent("\(driver).inf").path) else {
                throw WindowsDriversError.extractFailed
            }
            try FileManager.default.moveItem(at: build, to: destination.appendingPathComponent(driver))
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The driver install command, as base64 UTF-16 for `powershell -EncodedCommand`, so it
    /// needs no quoting inside the answer file.
    static var encodedInstallCommand: String {
        Data(WindowsDrivers.installCommand.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
    }

    static var autounattend: String { """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add"><Order>1</Order><Description>Install virtio drivers</Description><CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand \(encodedInstallCommand)</CommandLine></SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>

        """ }
}

enum WindowsDriversError: LocalizedError {
    case extractFailed

    var errorDescription: String? {
        "The virtio drivers could not be read from the driver ISO. Download the drivers again."
    }
}
