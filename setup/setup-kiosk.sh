#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_KIOSK_URL="http://192.168.100.38"
readonly KIOSK_URL="${1:-$DEFAULT_KIOSK_URL}"
readonly KIOSK_DIR="/root/counter_inspect"
readonly KIOSK_SCRIPT="$KIOSK_DIR/kiosk.sh"
readonly APP_REPOSITORY_URL="https://github.com/zack-cpp/HAS---Auto-Inspect-OPI.git"
readonly APP_DIR="$KIOSK_DIR/opi-app"
readonly APP_ENV_FILE="$APP_DIR/.env"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"
readonly MOSQUITTO_CONFIG="/etc/mosquitto/conf.d/counter-inspect.conf"
readonly MOSQUITTO_PASSWORD_FILE="/etc/mosquitto/passwd"
readonly MOSQUITTO_SYSTEMD_DIR="/etc/systemd/system/mosquitto.service.d"
readonly MOSQUITTO_SYSTEMD_CONFIG="$MOSQUITTO_SYSTEMD_DIR/counter-inspect.conf"
readonly MQTT_FIREWALL_SCRIPT="/usr/local/sbin/counter-inspect-mqtt-firewall"
readonly MQTT_FIREWALL_SERVICE="/etc/systemd/system/counter-inspect-mqtt-firewall.service"
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

Installs Docker Engine, Docker Compose, a password-protected local Mosquitto
broker, and a root-autologin X11/Chromium kiosk. It clones the application as:
  $APP_DIR

It also configures Ethernet sharing:
  eth0: DHCP client
  eth1: shared connection at 10.42.0.1/24

The Docker scanner is configured to use the kiosk's dedicated X11
authorization directory.

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

echo "Installing bootstrap, kiosk, and network-sharing packages..."
apt-get update
apt-get install -y \
    ca-certificates \
    chromium \
    curl \
    dnsmasq-base \
    git \
    iptables \
    mosquitto \
    mosquitto-clients \
    network-manager \
    openbox \
    xauth \
    x11-xserver-utils \
    xinit \
    xserver-xorg

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "Docker Engine and Docker Compose are already installed."
    else
        # Follow Docker's official apt-repository installation method. Remove
        # conflicting distro packages only when a working Engine + Compose
        # installation was not detected. Docker data under /var/lib/docker is
        # not removed by package removal.
        for conflicting_package in \
            docker.io \
            docker-compose \
            docker-compose-v2 \
            docker-doc \
            docker-buildx \
            podman-docker \
            containerd \
            runc; do
            apt-get remove -y "$conflicting_package" || true
        done

        # shellcheck disable=SC1091
        . /etc/os-release
        docker_distribution=""
        docker_codename="${VERSION_CODENAME:-}"
        if [[ "${ID:-}" == "ubuntu" || " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
            docker_distribution="ubuntu"
            docker_codename="${UBUNTU_CODENAME:-$docker_codename}"
        elif [[ "${ID:-}" == "debian" || " ${ID_LIKE:-} " == *" debian "* ]]; then
            docker_distribution="debian"
        fi
        if [[ -z "$docker_distribution" || -z "$docker_codename" ]]; then
            echo "Error: cannot determine a supported Ubuntu/Debian Docker repository." >&2
            exit 1
        fi

        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/$docker_distribution/gpg" \
            -o "$DOCKER_KEYRING"
        chmod a+r "$DOCKER_KEYRING"

        cat >"$DOCKER_SOURCES" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$docker_distribution
Suites: $docker_codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $DOCKER_KEYRING
EOF

        apt-get update
        apt-get install -y \
            containerd.io \
            docker-buildx-plugin \
            docker-ce \
            docker-ce-cli \
            docker-compose-plugin
    fi

    systemctl enable --now docker.service
    docker --version
    docker compose version
}

configure_mosquitto() {
    local config_tmp
    local password_tmp
    local username

    echo "Configuring the local Mosquitto broker..."
    install -d -o root -g root -m 0755 /etc/mosquitto/conf.d

    # Preserve all existing accounts. Missing managed accounts are created
    # interactively so plaintext passwords never enter this script, a process
    # argument, the repository, or the shell history.
    if [[ -f "$MOSQUITTO_PASSWORD_FILE" ]]; then
        password_tmp="$(mktemp /etc/mosquitto/passwd.tmp.XXXXXX)"
        awk -F: 'NF >= 2 && $1 != "" { print }' \
            "$MOSQUITTO_PASSWORD_FILE" >"$password_tmp"
        chown root:mosquitto "$password_tmp"
        chmod 0640 "$password_tmp"
        mv -f "$password_tmp" "$MOSQUITTO_PASSWORD_FILE"
    else
        install -o root -g mosquitto -m 0640 /dev/null "$MOSQUITTO_PASSWORD_FILE"
    fi

    for username in mqtt-stb andon_gateway; do
        if grep -Fq "${username}:" "$MOSQUITTO_PASSWORD_FILE"; then
            echo "Mosquitto account '$username' already exists; preserving it."
        else
            echo "Create the password for Mosquitto account '$username'."
            mosquitto_passwd "$MOSQUITTO_PASSWORD_FILE" "$username"
        fi
    done
    chown root:mosquitto "$MOSQUITTO_PASSWORD_FILE"
    chmod 0640 "$MOSQUITTO_PASSWORD_FILE"

    config_tmp="$(mktemp /etc/mosquitto/conf.d/counter-inspect.conf.tmp.XXXXXX)"
    cat >"$config_tmp" <<EOF
# Managed by setup-kiosk.sh. The counter-inspect-mqtt-firewall service limits
# access to loopback, Docker bridge interfaces, and eth1.
allow_anonymous false
password_file $MOSQUITTO_PASSWORD_FILE

listener 1883 0.0.0.0
EOF
    chown root:root "$config_tmp"
    chmod 0644 "$config_tmp"
    mv -f "$config_tmp" "$MOSQUITTO_CONFIG"

    # Listening on the IPv4 wildcard avoids startup failures while interfaces
    # are being created. Restrict ingress independently so MQTT is never
    # reachable through eth0 or any other unapproved host interface.
    cat >"$MQTT_FIREWALL_SCRIPT" <<'FIREWALL_EOF'
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
iptables -w -A "$MQTT_CHAIN" -i eth1 -j ACCEPT
iptables -w -A "$MQTT_CHAIN" -p tcp -j REJECT --reject-with tcp-reset

if ! iptables -w -C INPUT -p tcp --dport 1883 -j "$MQTT_CHAIN" 2>/dev/null; then
    iptables -w -I INPUT 1 -p tcp --dport 1883 -j "$MQTT_CHAIN"
fi
FIREWALL_EOF
    chmod 0755 "$MQTT_FIREWALL_SCRIPT"

    cat >"$MQTT_FIREWALL_SERVICE" <<EOF
[Unit]
Description=Restrict Counter Inspect MQTT broker ingress
Wants=docker.service
After=docker.service
Before=mosquitto.service

[Service]
Type=oneshot
ExecStart=$MQTT_FIREWALL_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$MQTT_FIREWALL_SERVICE"

    install -d -o root -g root -m 0755 "$MOSQUITTO_SYSTEMD_DIR"
    cat >"$MOSQUITTO_SYSTEMD_CONFIG" <<'EOF'
[Unit]
Requires=counter-inspect-mqtt-firewall.service
After=counter-inspect-mqtt-firewall.service
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=10s
EOF
    chmod 0644 "$MOSQUITTO_SYSTEMD_CONFIG"

    systemctl daemon-reload
    systemctl enable counter-inspect-mqtt-firewall.service
    systemctl restart counter-inspect-mqtt-firewall.service
    systemctl enable mosquitto.service
    systemctl restart mosquitto.service
    if ! systemctl is-active --quiet mosquitto.service; then
        echo "Error: Mosquitto did not start successfully." >&2
        journalctl --no-pager -n 50 -u mosquitto.service >&2 || true
        if [[ -r /var/log/mosquitto/mosquitto.log ]]; then
            echo "Last Mosquitto broker log entries:" >&2
            tail -n 50 /var/log/mosquitto/mosquitto.log >&2 || true
        fi
        exit 1
    fi
}

clone_application() {
    install -d -o root -g root -m 0755 "$KIOSK_DIR"

    if [[ -d "$APP_DIR/.git" ]]; then
        existing_origin="$(git -C "$APP_DIR" remote get-url origin 2>/dev/null || true)"
        echo "Application repository already exists at $APP_DIR."
        if [[ -n "$existing_origin" && "$existing_origin" != "$APP_REPOSITORY_URL" ]]; then
            echo "Warning: existing origin is $existing_origin" >&2
            echo "Expected origin: $APP_REPOSITORY_URL" >&2
        fi
        echo "Existing application files were preserved; run git pull --ff-only separately to update them."
        return
    fi

    if [[ -e "$APP_DIR" ]]; then
        echo "Error: $APP_DIR exists but is not a Git checkout." >&2
        echo "Move or remove that directory, then run this installer again." >&2
        exit 1
    fi

    echo "Cloning application repository into $APP_DIR..."
    git clone --origin origin "$APP_REPOSITORY_URL" "$APP_DIR"
}

install_docker
clone_application

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

configure_mosquitto

install -d -m 0755 "$KIOSK_DIR" "$URL_DIR" "$GETTY_DROPIN_DIR"
install -d -o root -g root -m 0750 "$XAUTHORITY_DIR"
install -d -o root -g root -m 1777 "$X11_SOCKET_DIR"

# Ensure Docker's read-only X11 socket bind source exists before containers are
# restored during boot, even if the kiosk X server has not started yet.
cat >"$X11_TMPFILES_CONFIG" <<EOF
d $X11_SOCKET_DIR 1777 root root -
EOF
chmod 0644 "$X11_TMPFILES_CONFIG"

# Keep unrelated Compose settings while replacing values owned by this kiosk
# installer. Mounting the Xauthority directory lets the scanner see a cookie
# file that xauth atomically replaces when X starts again.
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
        /^(OTA_HTTP_PORT|DISPLAY|XAUTHORITY_PATH|XAUTHORITY_DIR|X11_HOSTNAME)=/ { next }
        { print }
    ' "$APP_ENV_FILE" >"$env_tmp"
fi
if [[ -s "$env_tmp" ]]; then
    printf '\n' >>"$env_tmp"
fi
cat >>"$env_tmp" <<ENV_EOF
$ENV_BEGIN
OTA_HTTP_PORT=80
DISPLAY=:0
XAUTHORITY_DIR=$XAUTHORITY_DIR
X11_HOSTNAME=$X11_HOSTNAME
$ENV_END
ENV_EOF
install -o root -g root -m 0600 "$env_tmp" "$APP_ENV_FILE"
rm -f "$env_tmp"

cat >"$URL_FILE" <<EOF
$KIOSK_URL
EOF
chmod 0644 "$URL_FILE"

cat >"$KIOSK_SCRIPT" <<'KIOSK_EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

readonly URL_FILE="/etc/kiosk/url"
readonly CHROMIUM_RUNTIME_DIR="/run/counter-inspect/chromium"

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

# Never reuse Chromium's persistent default profile. Each kiosk launch gets a
# new profile under /run, which is cleared by Linux during every boot. This
# prevents an unclean power loss from leaving a stale SingletonLock behind.
install -d -o root -g root -m 0700 "$CHROMIUM_RUNTIME_DIR"
readonly CHROMIUM_PROFILE_DIR="$(mktemp -d "$CHROMIUM_RUNTIME_DIR/profile.XXXXXX")"

exec "$CHROMIUM_BIN" \
    --no-sandbox \
    --kiosk \
    --user-data-dir="$CHROMIUM_PROFILE_DIR" \
    --no-first-run \
    --no-default-browser-check \
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

Repository: $APP_REPOSITORY_URL
Application: $APP_DIR
URL:      $KIOSK_URL
Launcher: $KIOSK_SCRIPT
Autologin: root on tty1 via getty@tty1.service
Xauthority: $XAUTHORITY_FILE
X11 socket: $X11_SOCKET_DIR (created at boot by systemd-tmpfiles)
Ethernet: eth0 is a DHCP client
Sharing:  eth1 serves 10.42.0.0/24 from 10.42.0.1
MQTT:     authenticated Mosquitto on port 1883 for localhost, Docker, and eth1
Users:    mqtt-stb, andon_gateway

Reboot to start the kiosk:
  reboot

To change the URL later:
  printf '%s\n' 'https://example.com' > $URL_FILE

Initialize and start the application:
  cd $APP_DIR
  docker compose build
  docker compose run --rm counterctl init --device-id YOUR-DEVICE-ID
  docker compose up -d
EOF
