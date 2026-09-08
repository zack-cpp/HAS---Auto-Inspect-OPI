#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_KIOSK_URL="http://192.168.100.38"
readonly KIOSK_URL="${1:-$DEFAULT_KIOSK_URL}"
readonly KIOSK_DIR="/root/counter_inspect"
readonly KIOSK_SCRIPT="$KIOSK_DIR/kiosk.sh"
readonly APP_DIR="$KIOSK_DIR/opi-app"
readonly APP_ENV_FILE="$APP_DIR/.env"
readonly URL_DIR="/etc/kiosk"
readonly URL_FILE="$URL_DIR/url"
readonly XAUTHORITY_DIR="/etc/counter-inspect/xauth"
readonly XAUTHORITY_FILE="$XAUTHORITY_DIR/Xauthority"
readonly X11_HOSTNAME="$(hostname -s)"
readonly X11_SOCKET_DIR="/tmp/.X11-unix"
readonly X11_TMPFILES_CONFIG="/etc/tmpfiles.d/counter-inspect-x11.conf"
readonly GETTY_DROPIN_DIR="/etc/systemd/system/getty@tty1.service.d"
readonly GETTY_DROPIN="$GETTY_DROPIN_DIR/autologin.conf"
readonly PROFILE_FILE="/root/.bash_profile"
readonly PROFILE_BEGIN="# BEGIN managed kiosk startup"
readonly PROFILE_END="# END managed kiosk startup"
readonly ENV_BEGIN="# BEGIN managed kiosk X11"
readonly ENV_END="# END managed kiosk X11"

usage() {
    cat <<EOF
Usage: sudo bash $0 [URL]

Installs a root-autologin X11/Chromium kiosk and configures Ethernet sharing:
  eth0: DHCP client
  eth1: shared connection at 10.42.0.1/24

When $APP_DIR exists, also configures its Docker scanner to use the kiosk's
dedicated X11 authorization directory.

If URL is omitted, this is used:
  $DEFAULT_KIOSK_URL
EOF
}

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

if (( EUID != 0 )); then
    echo "Error: run this script as root." >&2
    exit 1
fi

case "$KIOSK_URL" in
    http://*|https://*) ;;
    *)
        echo "Error: URL must begin with http:// or https://" >&2
        exit 2
        ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: this installer requires an apt-based Debian/Ubuntu/Armbian system." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "Installing kiosk and network-sharing packages..."
apt-get update
apt-get install -y \
    ca-certificates \
    chromium \
    dnsmasq-base \
    network-manager \
    openbox \
    xauth \
    x11-xserver-utils \
    xinit \
    xserver-xorg

echo "Configuring eth0 as a DHCP client and eth1 as the shared connection..."
systemctl enable --now NetworkManager.service

if nmcli connection show wired-eth0 >/dev/null 2>&1; then
    nmcli connection modify wired-eth0 \
        connection.interface-name eth0 \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        802-3-ethernet.auto-negotiate yes \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.routes "" \
        ipv4.never-default no \
        ipv6.method auto
else
    nmcli connection add \
        type ethernet \
        ifname eth0 \
        con-name wired-eth0 \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        802-3-ethernet.auto-negotiate yes \
        ipv4.method auto \
        ipv6.method auto
fi

if nmcli connection show shared-eth1 >/dev/null 2>&1; then
    nmcli connection modify shared-eth1 \
        connection.interface-name eth1 \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        802-3-ethernet.auto-negotiate no \
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
        ifname eth1 \
        con-name shared-eth1 \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        802-3-ethernet.auto-negotiate no \
        ipv4.method shared \
        ipv4.addresses 10.42.0.1/24 \
        ipv4.never-default yes \
        ipv6.method disabled
fi

nmcli connection reload

if [[ -e /sys/class/net/eth1 ]]; then
    nmcli device set eth1 managed yes
    nmcli device set eth1 autoconnect yes
    if ! nmcli connection up shared-eth1 ifname eth1; then
        echo "Warning: shared-eth1 is saved but could not be activated now." >&2
        echo "It should autoconnect when the USB adapter and Ethernet link are available." >&2
    fi
else
    echo "Notice: eth1 is not currently present; shared-eth1 was saved for later." >&2
fi

install -d -m 0755 "$KIOSK_DIR" "$URL_DIR" "$GETTY_DROPIN_DIR"
install -d -o root -g root -m 0750 "$XAUTHORITY_DIR"
install -d -o root -g root -m 1777 "$X11_SOCKET_DIR"

# Ensure Docker's read-only X11 socket bind source exists before containers are
# restored during boot, even if the kiosk X server has not started yet.
cat >"$X11_TMPFILES_CONFIG" <<EOF
d $X11_SOCKET_DIR 1777 root root -
EOF
chmod 0644 "$X11_TMPFILES_CONFIG"

# Keep unrelated Compose settings, such as OTA_HTTP_PORT, while replacing only
# values owned by this kiosk installer. Mounting the directory lets the scanner
# see a cookie file that xauth atomically replaces when X starts again.
if [[ -d "$APP_DIR" ]]; then
    install -d -o 10001 -g 10001 -m 2770 \
        "$APP_DIR/config" \
        "$APP_DIR/logs" \
        "$APP_DIR/state/queue"
    install -d -o 10001 -g 10001 -m 2775 "$APP_DIR/updates"
    if [[ -f "$APP_DIR/config/credentials.enc" ]]; then
        chown 10001:10001 "$APP_DIR/config/credentials.enc"
        chmod 0640 "$APP_DIR/config/credentials.enc"
    fi

    env_tmp="$(mktemp "$APP_DIR/.env.tmp.XXXXXX")"
    if [[ -f "$APP_ENV_FILE" ]]; then
        awk -v begin="$ENV_BEGIN" -v end="$ENV_END" '
            $0 == begin { managed = 1; next }
            $0 == end { managed = 0; next }
            managed { next }
            /^(DISPLAY|XAUTHORITY_PATH|XAUTHORITY_DIR|X11_HOSTNAME)=/ { next }
            { print }
        ' "$APP_ENV_FILE" >"$env_tmp"
    fi
    if [[ -s "$env_tmp" ]]; then
        printf '\n' >>"$env_tmp"
    fi
    cat >>"$env_tmp" <<ENV_EOF
$ENV_BEGIN
DISPLAY=:0
XAUTHORITY_DIR=$XAUTHORITY_DIR
X11_HOSTNAME=$X11_HOSTNAME
$ENV_END
ENV_EOF
    install -o root -g root -m 0600 "$env_tmp" "$APP_ENV_FILE"
    rm -f "$env_tmp"
else
    echo "Notice: $APP_DIR does not exist; Docker .env was not updated." >&2
fi

cat >"$URL_FILE" <<EOF
$KIOSK_URL
EOF
chmod 0644 "$URL_FILE"

cat >"$KIOSK_SCRIPT" <<'KIOSK_EOF'
#!/usr/bin/env bash

set -u

readonly URL_FILE="/etc/kiosk/url"

if [[ ! -r "$URL_FILE" ]]; then
    echo "Kiosk URL file is missing: $URL_FILE" >&2
    exit 1
fi

KIOSK_URL="$(tr -d '\r\n' <"$URL_FILE")"
if [[ -z "$KIOSK_URL" ]]; then
    echo "Kiosk URL is empty: $URL_FILE" >&2
    exit 1
fi

# Allow the non-root scanner container (supplementary group 0) to read the
# current X11 cookie without making it world-readable.
if [[ -n "${XAUTHORITY:-}" ]] && [[ -f "$XAUTHORITY" ]]; then
    chmod 0640 "$XAUTHORITY"
fi

# Disable Linux virtual-console blanking before X takes over tty1.
if command -v setterm >/dev/null 2>&1; then
    setterm --blank 0 --powerdown 0 --powersave off \
        </dev/tty1 >/dev/tty1 2>/dev/null || true
fi

openbox-session &

# Disable the X11 screen saver, screen blanking, and DPMS power-off timers.
xset s off || true
xset s 0 0 || true
xset s noblank || true
xset dpms 0 0 0 || true
xset -dpms || true

sleep 2

if command -v chromium >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v chromium)"
elif command -v chromium-browser >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v chromium-browser)"
else
    echo "Chromium executable was not found." >&2
    exit 1
fi

exec "$CHROMIUM_BIN" \
    --no-sandbox \
    --kiosk \
    --no-first-run \
    --disable-session-crashed-bubble \
    --disable-infobars \
    "$KIOSK_URL"
KIOSK_EOF
chmod 0755 "$KIOSK_SCRIPT"

cat >"$GETTY_DROPIN" <<'GETTY_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
GETTY_EOF
chmod 0644 "$GETTY_DROPIN"

# Replace only this installer's managed block, preserving other profile content.
touch "$PROFILE_FILE"
profile_tmp="$(mktemp)"
trap 'rm -f "$profile_tmp"' EXIT
sed "/^${PROFILE_BEGIN}$/,/^${PROFILE_END}$/d" "$PROFILE_FILE" >"$profile_tmp"

if [[ -s "$profile_tmp" ]] && [[ "$(tail -c 1 "$profile_tmp" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$profile_tmp"
fi

cat >>"$profile_tmp" <<PROFILE_EOF
$PROFILE_BEGIN
if [ -z "\${DISPLAY:-}" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    export XAUTHORITY=$XAUTHORITY_FILE
    startx $KIOSK_SCRIPT
fi
$PROFILE_END
PROFILE_EOF

install -o root -g root -m 0644 "$profile_tmp" "$PROFILE_FILE"

systemctl daemon-reload
systemctl enable getty@tty1.service

if systemctl is-enabled display-manager.service >/dev/null 2>&1; then
    echo "Warning: a display manager is enabled and may conflict with startx on tty1." >&2
fi

cat <<EOF

Kiosk setup complete.

URL:      $KIOSK_URL
Launcher: $KIOSK_SCRIPT
Autologin: root on tty1 via getty@tty1.service
Xauthority: $XAUTHORITY_FILE
X11 socket: $X11_SOCKET_DIR (created at boot by systemd-tmpfiles)
Ethernet: eth0 is a DHCP client
Sharing:  eth1 serves 10.42.0.0/24 from 10.42.0.1

Reboot to start the kiosk:
  reboot

To change the URL later:
  printf '%s\n' 'https://example.com' > $URL_FILE
EOF
