#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_INSTALLER="$SCRIPT_DIR/setup-kiosk.sh"

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
if [[ "$model" != *"Orange Pi Zero 3"* ]]; then
    echo "Warning: detected hardware '$model'; this installer is tuned for Orange Pi Zero 3." >&2
fi

memory_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
echo "Orange Pi Zero 3 Noble low-memory setup (${memory_kib:-unknown} KiB RAM detected)."
echo "Using Surf/WebKitGTK instead of Chromium and enabling 50% compressed zram swap."

export COUNTER_KIOSK_BROWSER=surf
export COUNTER_KIOSK_LOW_MEMORY=1
exec bash "$BASE_INSTALLER" "$@"
