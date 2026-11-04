# PVMRunner

A native macOS app (Swift + SwiftUI) that runs ARM64 virtual machines with Apple's
**Virtualization.framework**. It can:

- import a Parallels Desktop `.pvm` bundle,
- import a disk image from another hypervisor: QCOW2 (QEMU, UTM), VMDK (VMware),
  VDI (VirtualBox), VHD/VHDX (Hyper-V) or raw `.img`,
- create a new VM and install an operating system from an ISO.

Originals are only ever read. Converted VMs live in
`~/Library/Application Support/PVMRunner/VMs/<name>/`:

```
vm.json            settings (CPU, RAM, network mode, MAC, ISO, …)
disk0.img          raw boot disk (sparse)
NVRAM              EFI variable store (Linux)
console.log        serial console output; console.in types into it
MachineIdentifier  platform identity
HardwareModel      macOS guests only
AuxiliaryStorage   macOS guests only
console.log        guest serial console output (hvc0)
```

## Requirements

| | |
|---|---|
| Mac | Apple Silicon (M1 or later). Intel Macs are not supported. |
| macOS | 14 Sonoma or later |
| Xcode | 15 or later (built and tested with Xcode 27.1) |
| qemu-img | `brew install qemu`. Looked up at `/opt/homebrew/bin/qemu-img`, then `/usr/local/bin/qemu-img`. |
| xcodegen | Optional: `brew install xcodegen`, only needed to regenerate the project from `project.yml`. |

## Building

### From the command line

```bash
xcodegen generate
```

```bash
xcodebuild -project PVMRunner.xcodeproj -scheme PVMRunner -configuration Release -derivedDataPath build/DerivedData build
```

The app is at `build/DerivedData/Build/Products/Release/PVMRunner.app`. Run the unit tests with:

```bash
xcodebuild -project PVMRunner.xcodeproj -scheme PVMRunner -derivedDataPath build/DerivedData test
```

### In Xcode and signing

1. Open `PVMRunner.xcodeproj` (run `xcodegen generate` first if it is missing).
2. By default the target is ad-hoc signed ("Sign to Run Locally", `CODE_SIGN_IDENTITY = -`).
   That is enough for `com.apple.security.virtualization`, so NAT networking works out of the box.
3. To sign with your team, open the **PVMRunner** target, then **Signing & Capabilities**:
   pick your **Team**, set signing to *Automatic* (or set `CODE_SIGN_STYLE`,
   `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = Apple Development` in `project.yml`).
4. Hardened Runtime stays on. App Sandbox is **off**, so the app can read `.pvm`
   bundles anywhere and run Homebrew's `qemu-img`. Turning the sandbox on would mean
   using security-scoped bookmarks for every chosen file and shipping `qemu-img` inside the app.
5. To distribute outside your Mac, sign with a *Developer ID Application* certificate
   and notarize it (`xcrun notarytool submit …`).

The entitlements are in `PVMRunner/Resources/PVMRunner.entitlements`.

## Using it

1. **File ▸ Import VM or Disk Image…** (⌘O), the toolbar **Import** button, or drag a
   `.pvm` or disk image onto the library window.
2. The summary sheet shows the guest OS, architecture, CPUs, memory, disks, network
   adapters and MAC address read from `config.pvs`. You can rename the VM, change CPUs
   and RAM, pick a network mode, and optionally grow the boot disk.
3. **Import** converts each disk with `qemu-img convert -f parallels -O raw`, with a progress
   bar and a Cancel button. Plain (preallocated) Parallels disks are converted with
   `-f raw`; raw `.img` files are cloned (APFS clone, instant).
4. Select the VM in the library to edit its settings (CPU, RAM, network mode, bridged
   interface, MAC, attached ISO). Changes apply on the next start.
5. **Start** opens the VM window. The toolbar has Start, Pause/Resume, Stop (asks the
   guest to shut down via `requestStop`) and Force Stop (immediate power off), plus the
   current state and a **Media** menu for the ISO. The guest display resizes with the window.

### Importing disk images from other hypervisors

Import a `.qcow2`, `.vmdk`, `.vdi`, `.vhd`, `.vhdx` or `.img` the same way as a `.pvm`.
`qemu-img info` detects the real format (a QCOW2 file named `.img` is still read as QCOW2),
then the image is converted to a raw disk in the VM folder. QCOW2 backing chains are
merged into one standalone disk. Encrypted images and other formats are refused with a message.

A disk image carries no VM settings, so the summary starts with 2 CPUs, 4 GB of memory and NAT.
The image must be an ARM64 guest that boots with UEFI. After conversion the boot disk's
EFI partition is checked, and x86 images are refused.

### Installing from an ISO

**File ▸ New VM from ISO…** (⌘N), the toolbar **+** button, or drag an `.iso` onto the library:

1. Choose an **ARM64 (aarch64)** installer ISO, such as Ubuntu for ARM, Fedora aarch64 or Debian arm64.
   The sheet reads the ISO's `/EFI/BOOT` loaders and blocks x86-only installers, which can't boot on Apple Silicon.
2. Set the name, CPUs, memory, disk size (sparse, so it only uses space as the guest writes) and network.
3. **Create and Start** makes an empty VM with the ISO attached read-only as a second virtio disk and boots the installer.
   Give desktop installers at least 6 GB of memory (the default is 8 GB): the live session keeps its changes in RAM.
4. When the install is done, use **Media ▸ Eject at Next Start** in the VM window. An ISO attached
   at startup can't be unplugged until the VM stops, but that's harmless: when the installer reboots,
   the firmware boots the installed system first.

### Removable media while the VM runs

On macOS 15 and later each VM gets a USB (XHCI) controller, so **Media ▸ Attach ISO…** in the
VM window hot-plugs an ISO or disk image into the running guest, and **Eject** or
**Replace ISO…** work on it live. On macOS 14, media changes apply at the next start. Media
attached in the VM window is remembered for the next start until you eject it.

### Guest devices

**Linux:** `VZEFIBootLoader` with a persistent `VZEFIVariableStore`, a virtio block disk,
a virtio GPU (`VZVirtioGraphicsDeviceConfiguration`, 1920×1200), virtio entropy,
a memory balloon, virtio net, a virtio console serial port logged to `console.log`,
a SPICE agent port for clipboard sharing (install `spice-vdagent` in the guest), and virtio sound.
Virtualization.framework has **no virtio keyboard or pointer**, so the app uses the
framework's USB keyboard and USB absolute pointing device, which every Linux kernel supports.

**macOS:** `VZMacOSBootLoader` with `VZMacPlatformConfiguration` (hardware model, machine
identifier, auxiliary storage copied from the bundle), Mac graphics, Mac keyboard and trackpad.

**ISO:** an optional `.iso` or `.img` attached read-only, for install or recovery media. At startup a
Linux guest gets it as a virtio block device (`/dev/vdb`), because live installers run their whole
root filesystem from it and the emulated USB stick can stall under that load and freeze the guest.
Media attached while the VM runs (macOS 15+) is a USB mass storage device, which can be ejected live.

### A frozen guest: the serial console

The guest's serial console (`hvc0` in Linux) is written to `console.log` in the VM folder, and
anything written to the `console.in` FIFO next to it is typed into the console. That reaches a guest
whose desktop has frozen, as long as it runs a getty on `hvc0` (Ubuntu does):

```bash
cd ~/Library/Application\ Support/PVMRunner/VMs/<name>
echo ubuntu > console.in        # log in (the Ubuntu live user has no password)
echo 'free -h; dmesg | tail' > console.in
tail -f console.log
```

### Converted Linux guests that do not boot

Parallels' EFI NVRAM cannot be carried over, so the new variable store starts empty and
the firmware boots the fallback loader `\EFI\BOOT\BOOTAA64.EFI`. Ubuntu, Debian and Fedora
install it. If you land in the UEFI shell, boot an install ISO in rescue mode and run
`grub-install --removable` (or copy `grubaa64.efi`/`shimaa64.efi` to `/EFI/BOOT/BOOTAA64.EFI`).
If the guest boots but has no network (no network icon in the top bar), check
`nmcli device` and `ip link` inside the guest. The virtio NIC gets a different
PCI address than under Parallels, so configuration pinned to the old interface name
(e.g. `enp0s5` in `/etc/netplan/*.yaml` or a NetworkManager profile) must be updated.
Guests that used a Parallels-specific driver (`prl_*` tools) keep working, but Parallels
Tools features are not available. Remove them in the guest if they cause errors.

## Supported guest matrix

| Guest | Status | Notes |
|---|---|---|
| ARM64 Linux | ✅ Supported | Ubuntu, Debian, Fedora, Kali, etc., from Parallels, from QCOW2/VMDK/VDI/VHD(X)/raw images, or installed from an ARM64 ISO. |
| ARM64 macOS | ⚠️ Partial | Only when the bundle contains the hardware model, machine identifier and auxiliary storage (Parallels `.macvm` bundles). Otherwise import is refused with an explanation. The host must support the guest's hardware model. |
| Windows (ARM or x86) | ❌ Not supported | Virtualization.framework does not provide the TPM, Secure Boot setup and drivers Windows needs. |
| Any x86 / Intel guest | ❌ Not supported | Virtualization.framework only runs ARM64 guests on Apple Silicon. Detected from config.pvs (legacy BIOS, x86 hints) and, after conversion, by inspecting the boot disk's GPT and EFI boot loader. |
| Encrypted VMs | ❌ Not supported | Decrypt in Parallels first (Configure ▸ Security). |
| VMs with snapshots | ⚠️ Partial | Only the base image is imported. Delete snapshots in Parallels first to merge them. |
| Split disks | ❌ Not supported | Merge the disk into a single file in Parallels first. |

## Networking

Each VM has a network mode:

- **NAT** (default): `VZNATNetworkDeviceAttachment`. The guest gets a private address and reaches the network through the host.
- **Bridged (socket_vmnet)**: the guest joins your LAN through the open-source
  [socket_vmnet](https://github.com/lima-vm/socket_vmnet) helper (also used by Lima and Colima).
  Works today, without Apple's approval. See below.
- **Bridged (entitlement)**: `VZBridgedNetworkDeviceAttachment` on an interface chosen from
  `VZBridgedNetworkInterface.networkInterfaces` (e.g. `en0`). Needs the restricted
  `com.apple.vm.networking` entitlement.
- **None**: no network device.

The original MAC address from `config.pvs` is kept if it is valid (unicast and not
all zeros). Otherwise a random locally administered address is generated. You can
regenerate it in the settings panel.

If bridged mode is selected but the app lacks the networking entitlement, or the
framework rejects the bridged attachment, the VM starts with NAT and the VM window
shows a banner explaining why.

### Bridged networking with socket_vmnet

socket_vmnet runs as root and uses Apple's vmnet framework in bridged mode, which needs root
but not the restricted entitlement. PVMRunner connects the VM's virtio NIC to it with
`VZFileHandleNetworkDeviceAttachment` and a small relay (`SocketVmnetRelay`) that converts
between the framework's one-frame-per-datagram socket and socket_vmnet's length-prefixed stream.

One-time setup (replace `en0` with the interface your Mac uses for the LAN, from `route get default`):

```bash
brew install socket_vmnet
```

```bash
sudo bash scripts/install-socket-vmnet-bridged.sh en0
```

The script copies the binary to root-owned `/opt/socket_vmnet/bin` (a root daemon should not run
from user-writable Homebrew paths), installs the LaunchDaemon
`io.github.lima-vm.socket_vmnet.bridged.en0` so the helper starts at boot, and creates the socket
`/var/run/socket_vmnet.bridged.en0`. The same script is bundled in the app, and the VM's Network
settings show its exact path, the helper's status, and copyable commands. Remove it with
`sudo bash scripts/install-socket-vmnet-bridged.sh --uninstall en0`.

Then choose **Bridged (socket_vmnet)** in the VM's settings and start it. If the helper is not
running, the VM starts on NAT and the VM window says why. When importing a VM that was bridged in
Parallels, this mode is preselected if the helper is running.

Bridged guests keep their LAN addresses: a guest with a static IP (as Parallels bridged VMs often
have) works unchanged, and DHCP guests get an address from your router.

### Requesting the bridged networking entitlement

`com.apple.vm.networking` is a **restricted entitlement**. Apple must grant it to your
developer team, and an app signed with it without approval will not launch. That is
why it is commented out in `PVMRunner.entitlements`.

1. Join the Apple Developer Program (a paid account).
2. Request it from Apple (Developer ▸ Contact Us ▸ *Development and Technical* ▸ *Entitlements*,
   or the entitlement request form when it is listed for your account). Explain that
   the app runs VMs with Virtualization.framework and needs bridged networking.
3. Once approved, enable the capability for your App ID in *Certificates, Identifiers & Profiles*
   and regenerate your provisioning profile so it includes `com.apple.vm.networking`.
4. Uncomment the entitlement in `PVMRunner/Resources/PVMRunner.entitlements`, set your team,
   and sign with that provisioning profile.

At runtime the app checks for the entitlement with `SecTaskCopyValueForEntitlement` and
only offers bridged interfaces when it is present.

## Architecture

MVVM, all VM work on the main actor (the `VZVirtualMachine` runs on the main queue):

| Layer | Files |
|---|---|
| Models | `Models/VMRecord.swift` (persisted JSON), `Models/ParsedPVM.swift` (parse result) |
| Services | `PVMParser` (config.pvs + DiskDescriptor.xml), `DiskImageInspector` (other hypervisors' images via `qemu-img info`), `VMFactory` (new VMs for ISO installs), `DiskConverter` (qemu-img convert/resize with progress), `ArchitectureProbe` (GPT / EFI boot loader check), `VMConfigurationBuilder` (`VZVirtualMachineConfiguration` for Linux and macOS, network fallback), `VMLibraryStore` (folders + JSON) |
| View models | `VMController` (one VM: start, pause, resume, stop, force stop, state via KVO), `LibraryViewModel`, `ImportViewModel` |
| Views | `LibraryView` (table + drag and drop), `VMDetailView` (settings panel), `ImportSheet` (summary, progress, errors), `NewVMSheet` (install from ISO), `VMWindowView` (`VZVirtualMachineView` + toolbar) |

`project.yml` is the source of truth for the Xcode project. Run `xcodegen generate` after adding files.

The app icon is drawn in code by `scripts/make-icon.swift`. After changing it, regenerate every size with
`swift scripts/make-icon.swift PVMRunner/Resources/Assets.xcassets/AppIcon.appiconset`.
