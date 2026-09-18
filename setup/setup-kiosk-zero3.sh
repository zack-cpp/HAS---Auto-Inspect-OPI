#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_INSTALLER="$SCRIPT_DIR/setup-kiosk.sh"
readonly ZERO3_SETUP_REVISION="zero3-dbus-auto-interface-v2"
readonly KIOSK_SCRIPT="/root/counter_inspect/kiosk.sh"
readonly KIOSK_PROFILE="/root/.bash_profile"
readonly KIOSK_LOG="/var/log/counter-inspect-kiosk.log"
readonly ZRAM_CONFIG="/etc/default/zramswap"
readonly MQTT_FIREWALL_SCRIPT="/usr/local/sbin/counter-inspect-mqtt-firewall"
readonly GETTY_DROPIN="/etc/systemd/system/getty@tty1.service.d/autologin.conf"
readonly KIOSK_SERVICE="/etc/systemd/system/counter-inspect-kiosk.service"
readonly KIOSK_RESTART_SERVICE="/etc/systemd/system/counter-inspect-kiosk-restart.service"
readonly KIOSK_RESTART_REQUEST="/etc/kiosk/restart-request"
readonly PROFILE_BEGIN="# BEGIN managed kiosk startup"
readonly PROFILE_END="# END managed kiosk startup"
readonly LOW_MEMORY_SYSCTL="/etc/sysctl.d/90-counter-inspect-low-memory.conf"
COUNTER_INTERFACE=""

detect_counter_interface() {
    local candidate
    local device_type
    local requested="${COUNTER_ZERO3_INTERFACE:-}"

    if [[ -n "$requested" ]]; then
        if [[ ! "$requested" =~ ^[[:alnum:]_.:-]{1,15}$ ]] || [[ ! -e "/sys/class/net/$requested" ]]; then
            echo "Error: COUNTER_ZERO3_INTERFACE is not a local network interface: $requested" >&2
            return 1
        fi
        printf '%s\n' "$requested"
        return
    fi

    # Prefer the names used by Orange Pi images, then accept the first wired
    # NetworkManager device. Virtual Docker/veth interfaces are not TYPE=ethernet.
    for candidate in end0 eth0; do
        if [[ -e "/sys/class/net/$candidate/device" ]]; then
            device_type="$(nmcli -g GENERAL.TYPE device show "$candidate" 2>/dev/null || true)"
            if [[ "$device_type" == "ethernet" ]]; then
                printf '%s\n' "$candidate"
                return
            fi
        fi
    done

    while IFS=: read -r candidate device_type; do
        if [[ "$device_type" == "ethernet" ]] && [[ -e "/sys/class/net/$candidate/device" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done < <(nmcli -t -f DEVICE,TYPE device status)

    echo "Error: no physical Ethernet interface was detected." >&2
    echo "Set COUNTER_ZERO3_INTERFACE explicitly and rerun the installer." >&2
    return 1
}

configure_zero3_zram() {
    local candidate
    local supported_algorithms=""
    local zram_algorithm="lzo"

    cat >"$LOW_MEMORY_SYSCTL" <<'EOF'
# Prefer the operating system's compressed zram swap under memory pressure.
vm.swappiness=100
vm.page-cluster=0
EOF
    chmod 0644 "$LOW_MEMORY_SYSCTL"
    sysctl --load="$LOW_MEMORY_SYSCTL"

    # Orange Pi OS already manages zram0 as swap and zram1 for compressed logs.
    # Never reset those live devices or run a second zram manager against them.
    if swapon --noheadings --raw --show=NAME 2>/dev/null | grep -q '^/dev/zram'; then
        systemctl disable zramswap.service >/dev/null 2>&1 || true
        echo "Using the operating system's existing zram devices:"
        zramctl || true
        return
    fi

    apt-get install -y kmod zram-tools

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
    local shared_connection

    COUNTER_INTERFACE="$(detect_counter_interface)"
    shared_connection="shared-$COUNTER_INTERFACE"
    echo "Applying Orange Pi Zero 3 network mapping: $COUNTER_INTERFACE is the shared counter LAN..."

    # Keep an SSH session using the wired interface alive during installation,
    # but prevent the DHCP profile from winning after reboot.
    if nmcli connection show wired-eth0 >/dev/null 2>&1; then
        nmcli connection modify wired-eth0 connection.autoconnect no
    fi
    if nmcli connection show "wired-$COUNTER_INTERFACE" >/dev/null 2>&1; then
        nmcli connection modify "wired-$COUNTER_INTERFACE" connection.autoconnect no
    fi

    if nmcli connection show "$shared_connection" >/dev/null 2>&1; then
        nmcli connection modify "$shared_connection" \
            connection.interface-name "$COUNTER_INTERFACE" \
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
            ifname "$COUNTER_INTERFACE" \
            con-name "$shared_connection" \
            connection.autoconnect yes \
            connection.autoconnect-priority 200 \
            802-3-ethernet.auto-negotiate yes \
            ipv4.method shared \
            ipv4.addresses 10.42.0.1/24 \
            ipv4.never-default yes \
            ipv6.method disabled
    fi

    # A base-installer run creates this profile even though the Zero3 has no
    # eth1. Leave it available for recovery, but never auto-activate it.
    for obsolete_connection in shared-eth0 shared-eth1; do
        if [[ "$obsolete_connection" != "$shared_connection" ]] && \
            nmcli connection show "$obsolete_connection" >/dev/null 2>&1; then
            nmcli connection modify "$obsolete_connection" connection.autoconnect no
        fi
    done
    nmcli connection reload

    # The base installer intentionally protects MQTT from every interface
    # except its counter LAN. Recreate the same narrow policy for the detected
    # Zero3 Ethernet interface.
    cat >"$MQTT_FIREWALL_SCRIPT" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

readonly MQTT_CHAIN="COUNTER_MQTT"
readonly COUNTER_INTERFACE="$COUNTER_INTERFACE"

if iptables -w -N "\$MQTT_CHAIN" 2>/dev/null; then
    :
else
    iptables -w -F "\$MQTT_CHAIN"
fi

iptables -w -A "\$MQTT_CHAIN" -i lo -j ACCEPT
iptables -w -A "\$MQTT_CHAIN" -i docker0 -j ACCEPT
iptables -w -A "\$MQTT_CHAIN" -i 'br+' -j ACCEPT
iptables -w -A "\$MQTT_CHAIN" -i "\$COUNTER_INTERFACE" -j ACCEPT
iptables -w -A "\$MQTT_CHAIN" -p tcp -j REJECT --reject-with tcp-reset

if ! iptables -w -C INPUT -p tcp --dport 1883 -j "\$MQTT_CHAIN" 2>/dev/null; then
    iptables -w -I INPUT 1 -p tcp --dport 1883 -j "\$MQTT_CHAIN"
fi
EOF
    chmod 0755 "$MQTT_FIREWALL_SCRIPT"
    systemctl restart counter-inspect-mqtt-firewall.service

    echo "Saved $shared_connection without interrupting the current connection."
    echo "After reboot, $COUNTER_INTERFACE will use 10.42.0.1/24; upstream access must use Wi-Fi or another interface."
}

configure_zero3_kiosk() {
    local launcher_tmp
    local profile_tmp

    apt-get install -y dbus-x11 python3-xdg xserver-xorg-video-fbdev

    # Stop an older restart loop before replacing its launcher and unit.
    systemctl stop counter-inspect-kiosk.service >/dev/null 2>&1 || true

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

    # Zero3 starts its kiosk directly from systemd. Remove the base installer's
    # login-shell hook and root-autologin override while preserving unrelated
    # root profile content.
    profile_tmp="$(mktemp)"
    sed "/^${PROFILE_BEGIN}$/,/^${PROFILE_END}$/d" "$KIOSK_PROFILE" >"$profile_tmp"
    install -o root -g root -m 0644 "$profile_tmp" "$KIOSK_PROFILE"
    rm -f "$profile_tmp"

    rm -f "$GETTY_DROPIN"

    cat >"$KIOSK_SERVICE" <<EOF
[Unit]
Description=Counter Inspect Zero3 X11 kiosk
Wants=network-online.target
After=network-online.target systemd-user-sessions.service getty@tty1.service
Conflicts=getty@tty1.service
StartLimitIntervalSec=60
StartLimitBurst=6

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=HOME=/root
Environment=XAUTHORITY=/etc/counter-inspect/xauth/Xauthority
Environment=GDK_BACKEND=x11
TTYPath=/dev/tty1
StandardInput=tty-force
StandardOutput=append:$KIOSK_LOG
StandardError=append:$KIOSK_LOG
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/startx $KIOSK_SCRIPT -- :0 vt1 -keeptty -nolisten tcp
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$KIOSK_SERVICE"

    # Keep `counterctl kiosk restart` working, but restart the dedicated kiosk
    # service rather than the no-longer-used autologin getty.
    cat >"$KIOSK_RESTART_SERVICE" <<EOF
[Unit]
Description=Apply a Counter Inspect kiosk restart request

[Service]
Type=oneshot
ExecStart=/bin/rm -f $KIOSK_RESTART_REQUEST
ExecStart=/usr/bin/systemctl --no-block restart counter-inspect-kiosk.service
EOF
    chmod 0644 "$KIOSK_RESTART_SERVICE"

    systemctl daemon-reload
    systemctl disable getty@tty1.service >/dev/null 2>&1 || true
    systemctl reset-failed counter-inspect-kiosk.service >/dev/null 2>&1 || true
    systemctl enable --now counter-inspect-kiosk.service
    systemctl enable counter-inspect-kiosk-restart.path

    sleep 6
    if systemctl is-active --quiet counter-inspect-kiosk.service; then
        echo "Zero3 kiosk service is running."
    else
        echo "Warning: Zero3 kiosk service did not stay active." >&2
        systemctl status --no-pager -l counter-inspect-kiosk.service >&2 || true
        journalctl --no-pager -n 80 -u counter-inspect-kiosk.service >&2 || true
        tail -n 100 "$KIOSK_LOG" >&2 || true
    fi
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
echo "Setup revision: $ZERO3_SETUP_REVISION"
echo "Using Surf/WebKitGTK instead of Chromium and preserving OS-managed zram."

export COUNTER_KIOSK_BROWSER=surf
# Orange Pi OS already supplies correctly sized zram swap and compressed logs.
# Do not let the base installer add the conflicting zram-tools manager.
export COUNTER_KIOSK_LOW_MEMORY=0
bash "$BASE_INSTALLER" "$@"

configure_zero3_zram
configure_zero3_network
configure_zero3_kiosk

cat <<EOF

Orange Pi Zero 3 adjustments complete.

Counter LAN: $COUNTER_INTERFACE at 10.42.0.1/24 after reboot
Upstream:    Wi-Fi or another system-managed interface
Kiosk log:  $KIOSK_LOG
Startup:    counter-inspect-kiosk.service (no tty autologin)

The kiosk service has been started now. Reboot to activate the Zero3 network profile:
  reboot
EOF
