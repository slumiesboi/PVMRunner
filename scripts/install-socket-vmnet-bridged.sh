#!/bin/bash
# Installs socket_vmnet's bridged helper as a LaunchDaemon so PVMRunner VMs in
# "Bridged (socket_vmnet)" mode can join the host's local network.
#
#   sudo bash install-socket-vmnet-bridged.sh [interface]              # default: en0
#   sudo bash install-socket-vmnet-bridged.sh --uninstall [interface]
#
# Requires: brew install socket_vmnet
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this with sudo: sudo bash $0 ${*:-en0}" >&2
    exit 1
fi

uninstall=false
if [[ ${1:-} == "--uninstall" ]]; then
    uninstall=true
    shift
fi
interface=${1:-en0}
if [[ ! ${interface} =~ ^[a-z]+[0-9]+$ ]]; then
    echo "Invalid interface name: ${interface}" >&2
    exit 1
fi

label="io.github.lima-vm.socket_vmnet.bridged.${interface}"
plist="/Library/LaunchDaemons/${label}.plist"
socket="/var/run/socket_vmnet.bridged.${interface}"

if ${uninstall}; then
    launchctl bootout "system/${label}" 2>/dev/null || true
    [[ -f ${plist} ]] && rm "${plist}"
    echo "Removed the socket_vmnet bridged helper for ${interface}."
    exit 0
fi

if ! ifconfig "${interface}" >/dev/null 2>&1; then
    echo "Network interface ${interface} does not exist. Pick one from: $(ifconfig -l)" >&2
    exit 1
fi

source_binary=""
for candidate in /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /usr/local/opt/socket_vmnet/bin/socket_vmnet; do
    if [[ -x ${candidate} ]]; then
        source_binary=${candidate}
        break
    fi
done
if [[ -z ${source_binary} ]]; then
    echo "socket_vmnet is not installed. Run: brew install socket_vmnet" >&2
    exit 1
fi

# The daemon runs as root, so run a root-owned copy rather than the user-writable Homebrew one.
binary=/opt/socket_vmnet/bin/socket_vmnet
install -d -o root -g wheel -m 755 /opt/socket_vmnet/bin
install -o root -g wheel -m 755 "${source_binary}" "${binary}"

cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${binary}</string>
        <string>--vmnet-mode=bridged</string>
        <string>--vmnet-interface=${interface}</string>
        <string>--socket-group=staff</string>
        <string>${socket}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>UserName</key>
    <string>root</string>
    <key>StandardErrorPath</key>
    <string>/var/log/socket_vmnet.bridged.${interface}.log</string>
</dict>
</plist>
EOF
chown root:wheel "${plist}"
chmod 644 "${plist}"

launchctl bootout "system/${label}" 2>/dev/null || true
launchctl bootstrap system "${plist}"

for _ in $(seq 1 20); do
    if [[ -S ${socket} ]]; then
        echo "socket_vmnet is bridging ${interface} at ${socket}."
        echo "In PVMRunner, set the VM's network mode to \"Bridged (socket_vmnet)\" and start it."
        exit 0
    fi
    sleep 0.5
done
echo "The helper did not create ${socket}. Check /var/log/socket_vmnet.bridged.${interface}.log" >&2
exit 1
