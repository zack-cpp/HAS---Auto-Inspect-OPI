#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_INSTALLER="$SCRIPT_DIR/setup-kiosk.sh"
readonly KIOSK_SCRIPT="/root/counter_inspect/kiosk.sh"
readonly KIOSK_PROFILE="/root/.bash_profile"
readonly KIOSK_LOG="/var/log/counter-inspect-kiosk.log"
readonly ZRAM_CONFIG="/etc/default/zramswap"
readonly MQTT_FIREWALL_SCRIPT="/usr/local/sbin/counter-inspect-mqtt-firewall"

configure_zero3_zram() {
    local candidate
    local supported_algorithms=""
    local zram_algorithm="lzo"

    if modprobe zram >/dev/null 2>&1 && [[ -r /sys/block/zram0/comp_algorithm ]]; then
        supported_algorithms="$(tr -d '[]' </sys/block/zram0/comp_algorithm)"
        for candidate in lz4 lzo-rle lzo; do
            if grep -qw -- "$candidate" <<<"$supported_algorithms"; then
                zram_algorithm="$candidate"
                break
            fi
        done
    fi

    cat >"$ZRAM_CONFIG" <<EOF
ALGO=$zram_algorithm
PERCENT=50
PRIORITY=100
EOF
    chmod 0644 "$ZRAM_CONFIG"

    if systemctl restart zramswap.service; then
        echo "Enabled compressed zram swap using $zram_algorithm."
    else
        echo "Warning: zram could not be enabled on this kernel." >&2
        systemctl status --no-pager -l zramswap.service >&2 || true
        journalctl --no-pager -n 40 -u zramswap.service >&2 || true
        zramctl >&2 || true
    fi
}

configure_zero3_network() {
    echo "Applying Orange Pi Zero 3 network mapping: eth0 is the shared counter LAN..."

    # Keep an SSH session using eth0 alive for the remainder of installation,
    # but prevent the DHCP profile from winning after reboot.
    if nmcli connection show wired-eth0 >/dev/null 2>&1; then
        nmcli connection modify wired-eth0 connection.autoconnect no
    fi

    if nmcli connection show shared-eth0 >/dev/null 2>&1; then
        nmcli connection modify shared-eth0 \
            connection.interface-name eth0 \
            connection.autoconnect yes \
            connection.autoconnect-priority 200 \
            802-3-ethernet.auto-negotiate yes \
            ipv4.method shared \
            ipv4.addresses 10.42.0.1/24 \
            ipv4.gateway "" \
            ipv4.dns "" \
            ipv4.routes "" \
            ipv4.never-default yes \
            ipv6.method disabled
    else
        nmcli connection add \
            type ethernet \
            ifname eth0 \
            con-name shared-eth0 \
            connection.autoconnect yes \
            connection.autoconnect-priority 200 \
            802-3-ethernet.auto-negotiate yes \
            ipv4.method shared \
            ipv4.addresses 10.42.0.1/24 \
            ipv4.never-default yes \
            ipv6.method disabled
    fi

    # A previous base-installer run creates this profile even though the Zero3
    # has no eth1. Leave it available for recovery, but never auto-activate it.
    if nmcli connection show shared-eth1 >/dev/null 2>&1; then
        nmcli connection modify shared-eth1 connection.autoconnect no
    fi
    nmcli connection reload

    # The base installer intentionally protects MQTT from every interface
    # except its counter LAN. Recreate the same narrow policy for Zero3 eth0.
    cat >"$MQTT_FIREWALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

readonly MQTT_CHAIN="COUNTER_MQTT"

if iptables -w -N "$MQTT_CHAIN" 2>/dev/null; then
    :
else
    iptables -w -F "$MQTT_CHAIN"
fi

iptables -w -A "$MQTT_CHAIN" -i lo -j ACCEPT
iptables -w -A "$MQTT_CHAIN" -i docker0 -j ACCEPT
iptables -w -A "$MQTT_CHAIN" -i 'br+' -j ACCEPT
iptables -w -A "$MQTT_CHAIN" -i eth0 -j ACCEPT
iptables -w -A "$MQTT_CHAIN" -p tcp -j REJECT --reject-with tcp-reset

if ! iptables -w -C INPUT -p tcp --dport 1883 -j "$MQTT_CHAIN" 2>/dev/null; then
    iptables -w -I INPUT 1 -p tcp --dport 1883 -j "$MQTT_CHAIN"
fi
EOF
    chmod 0755 "$MQTT_FIREWALL_SCRIPT"
    systemctl restart counter-inspect-mqtt-firewall.service

    echo "Saved shared-eth0 without interrupting the current connection."
    echo "After reboot, eth0 will use 10.42.0.1/24; upstream access must use Wi-Fi or another interface."
}

configure_zero3_kiosk() {
    local launcher_tmp
    local profile_tmp

    apt-get install -y dbus-x11 xserver-xorg-video-fbdev

    if [[ ! -r "$KIOSK_SCRIPT" ]]; then
        echo "Error: base installer did not create $KIOSK_SCRIPT" >&2
        exit 1
    fi

    # WebKitGTK's DMA-BUF renderer is unreliable with the Zero3 vendor GPU
    # stack. Apply this only to Surf in the generated Zero3 launcher.
    launcher_tmp="$(mktemp)"
    sed 's/^    surf \\/    WEBKIT_DISABLE_DMABUF_RENDERER=1 surf \\/' \
        "$KIOSK_SCRIPT" >"$launcher_tmp"
    install -o root -g root -m 0755 "$launcher_tmp" "$KIOSK_SCRIPT"
    rm -f "$launcher_tmp"

    touch "$KIOSK_LOG"
    chmod 0644 "$KIOSK_LOG"

    # Preserve the base installer's managed login block while making Xorg,
    # Openbox, and Surf failures available after reboot.
    profile_tmp="$(mktemp)"
    sed "s|^    startx $KIOSK_SCRIPT$|    startx $KIOSK_SCRIPT >>$KIOSK_LOG 2>\&1|" \
        "$KIOSK_PROFILE" >"$profile_tmp"
    install -o root -g root -m 0644 "$profile_tmp" "$KIOSK_PROFILE"
    rm -f "$profile_tmp"
}

if (( EUID != 0 )); then
    echo "Error: run this script as root." >&2
    exit 1
fi

if [[ ! -r "$BASE_INSTALLER" ]]; then
    echo "Error: the shared installer is missing: $BASE_INSTALLER" >&2
    echo "Copy the complete setup directory or run this script from the repository checkout." >&2
    exit 1
fi

if [[ "$(dpkg --print-architecture 2>/dev/null || true)" != "arm64" ]]; then
    echo "Error: the Orange Pi Zero 3 installer requires an arm64 userspace." >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
os_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ "${ID:-}" != "ubuntu" && " ${ID_LIKE:-} " != *" ubuntu "* ]]; then
    echo "Error: this variant requires Ubuntu or an Ubuntu-derived OS." >&2
    exit 1
fi
if [[ "$os_codename" != "noble" ]]; then
    echo "Error: this variant targets Ubuntu Noble (24.04), not '$os_codename'." >&2
    exit 1
fi

model="unknown"
if [[ -r /proc/device-tree/model ]]; then
    model="$(tr -d '\0' </proc/device-tree/model)"
fi
if [[ "$model" != *"Orange Pi Zero 3"* && "$model" != *"OrangePi Zero3"* ]]; then
    echo "Warning: detected hardware '$model'; this installer is tuned for Orange Pi Zero 3." >&2
fi

memory_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
echo "Orange Pi Zero 3 Noble low-memory setup (${memory_kib:-unknown} KiB RAM detected)."
echo "Using Surf/WebKitGTK instead of Chromium and enabling 50% compressed zram swap."

export COUNTER_KIOSK_BROWSER=surf
export COUNTER_KIOSK_LOW_MEMORY=1
bash "$BASE_INSTALLER" "$@"

configure_zero3_zram
configure_zero3_network
configure_zero3_kiosk

cat <<EOF

Orange Pi Zero 3 adjustments complete.

Counter LAN: eth0 at 10.42.0.1/24 after reboot
Upstream:    Wi-Fi or another system-managed interface
Kiosk log:  $KIOSK_LOG

Reboot to activate the Zero3 network profile and kiosk:
  reboot
EOF
