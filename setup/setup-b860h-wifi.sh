#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly FIRMWARE_DIR="$REPOSITORY_DIR/firmware"
readonly DRIVER_PATCH="$FIRMWARE_DIR/patches/rtl8189fs-linux-6.12-monitor-channel.patch"
readonly MODULES_FILE="$FIRMWARE_DIR/rtl8189fs.modules"
readonly DRIVER_REPOSITORY_URL="https://github.com/jwrdegoede/rtl8189ES_linux.git"
readonly DRIVER_SOURCE_DIR="/usr/src/rtl8189ES_linux"
readonly DRIVER_COMMIT="a5ad16ed1d64fe1facce95bbcc2360c8c846a681"
readonly EXPECTED_SDIO_ID="024C:F179"
readonly STOCK_FDT="/dtb/amlogic/meson-gxl-s905x-b860h.dtb"
readonly CUSTOM_FDT="/dtb/amlogic/meson-gxl-s905x-b860h-rtl8189fs.dtb"
readonly UENV_FILE="/boot/uEnv.txt"
readonly MODULES_LOAD_FILE="/etc/modules-load.d/8189fs.conf"

CONFIRM_HARDWARE=false
REBOOT_AFTER_INSTALL=false
MODE="install"
WORK_DIR=""

usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Builds and installs the RTL8189FS Wi-Fi driver and corrected B860H device tree.
Run this script from a complete HAS - Auto Inspect OPI repository checkout.

Options:
  --confirm-hardware  Confirm this unit has the RTL8189FTV/RTL8189FS module and
                      GPIOX_6 wiring when the unpowered SDIO device cannot report
                      its identity. Not needed when SDIO ID $EXPECTED_SDIO_ID is visible.
  --reboot            Reboot automatically after a successful installation.
  --verify            Only verify a previously installed update; make no changes.
  -h, --help          Show this help text.

Examples:
  sudo bash $0 --confirm-hardware
  sudo bash $0 --confirm-hardware --reboot
  sudo bash $0 --verify
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT

while (( $# > 0 )); do
    case "$1" in
        --confirm-hardware)
            CONFIRM_HARDWARE=true
            ;;
        --reboot)
            REBOOT_AFTER_INSTALL=true
            ;;
        --verify)
            MODE="verify"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

if (( EUID != 0 )); then
    die "run this script as root."
fi

if [[ "$MODE" == "verify" && "$REBOOT_AFTER_INSTALL" == true ]]; then
    die "--verify and --reboot cannot be used together."
fi

read_compatible_strings() {
    tr '\0' '\n' </proc/device-tree/compatible
}

read_active_fdt() {
    awk -F= '
        /^FDT=/ {
            value = substr($0, index($0, "=") + 1)
            count++
        }
        END {
            if (count != 1 || value == "")
                exit 1
            print value
        }
    ' "$UENV_FILE"
}

read_sdio_ids() {
    local uevent

    for uevent in /sys/bus/sdio/devices/*/uevent; do
        [[ -e "$uevent" ]] || continue
        sed -n 's/^SDIO_ID=//p' "$uevent"
    done
}

preflight_board() {
    local active_fdt
    local architecture

    [[ -r /proc/device-tree/compatible ]] || die "device-tree compatible data is unavailable."
    if ! read_compatible_strings | grep -Fxq 'zte,b860h'; then
        echo "Detected compatible strings:" >&2
        read_compatible_strings >&2
        die "this installer only supports the ZTE B860H device tree."
    fi

    architecture="$(dpkg --print-architecture 2>/dev/null || true)"
    [[ "$architecture" == "arm64" ]] || die "expected arm64, detected '${architecture:-unknown}'."

    [[ -r "$UENV_FILE" ]] || die "$UENV_FILE is missing or unreadable."
    active_fdt="$(read_active_fdt)" || die "$UENV_FILE must contain exactly one non-empty FDT= line."
    case "$active_fdt" in
        "$STOCK_FDT"|"$CUSTOM_FDT") ;;
        *) die "unsupported active FDT '$active_fdt'; expected $STOCK_FDT or $CUSTOM_FDT." ;;
    esac

    printf 'Board:      %s\n' "$(tr -d '\0' </proc/device-tree/model)"
    printf 'Compatible: zte,b860h\n'
    printf 'Architecture: %s\n' "$architecture"
    printf 'Kernel:     %s\n' "$(uname -r)"
    printf 'Active FDT: %s\n' "$active_fdt"
}

preflight_hardware() {
    local detected_id
    local found_expected=false
    local found_other=false

    while IFS= read -r detected_id; do
        [[ -n "$detected_id" ]] || continue
        printf 'Detected SDIO ID: %s\n' "$detected_id"
        if [[ "$detected_id" == "$EXPECTED_SDIO_ID" ]]; then
            found_expected=true
        else
            found_other=true
        fi
    done < <(read_sdio_ids)

    if [[ "$found_other" == true ]]; then
        die "an SDIO device other than $EXPECTED_SDIO_ID is present; refusing to install this driver."
    fi
    if [[ "$found_expected" == true ]]; then
        return
    fi
    if [[ "$CONFIRM_HARDWARE" != true ]]; then
        cat >&2 <<EOF
No SDIO identity is currently visible. This is expected when the stock device
tree leaves the radio unpowered, but B860H revisions can contain other chipsets.

Verify that this machine has the RTL8189FTV/RTL8189FS module and GPIOX_6 wiring,
then rerun with --confirm-hardware. Do not use that option speculatively.
EOF
        exit 1
    fi

    echo "SDIO is not enumerated; proceeding on the operator's explicit hardware confirmation."
}

require_ethernet_link() {
    local interface_path

    for interface_path in /sys/class/net/eth*; do
        [[ -e "$interface_path/operstate" ]] || continue
        if [[ "$(<"$interface_path/operstate")" == "up" ]]; then
            printf 'Ethernet:   %s is up\n' "${interface_path##*/}"
            return
        fi
    done

    die "no active Ethernet interface was found; keep a wired recovery path connected during installation."
}

verify_installation() {
    local access_point_count
    local active_fdt
    local detected_driver=""
    local detected_id=""
    local uevent

    log "Verifying the running Wi-Fi installation"
    active_fdt="$(read_active_fdt)"
    [[ "$active_fdt" == "$CUSTOM_FDT" ]] || die "the corrected device tree is not active."

    for uevent in /sys/bus/sdio/devices/*/uevent; do
        [[ -e "$uevent" ]] || continue
        if grep -Fxq "SDIO_ID=$EXPECTED_SDIO_ID" "$uevent"; then
            detected_id="$(sed -n 's/^SDIO_ID=//p' "$uevent")"
            detected_driver="$(sed -n 's/^DRIVER=//p' "$uevent")"
            break
        fi
    done

    [[ "$detected_id" == "$EXPECTED_SDIO_ID" ]] || die "SDIO device $EXPECTED_SDIO_ID is not enumerated."
    [[ "$detected_driver" == "rtl8189fs" ]] || die "SDIO device is not bound to rtl8189fs."
    grep -q '^8189fs ' /proc/modules || die "8189fs is not loaded."
    grep -q '^cfg80211 ' /proc/modules || die "cfg80211 is not loaded."
    [[ -d /sys/class/net/wlan0 ]] || die "wlan0 is missing."
    systemctl is-active --quiet NetworkManager.service || die "NetworkManager is not active."

    if rfkill list wifi | grep -Eq 'Soft blocked: yes|Hard blocked: yes'; then
        rfkill list wifi >&2
        die "Wi-Fi is blocked by rfkill."
    fi

    nmcli device wifi rescan ifname wlan0
    access_point_count="$(nmcli -t -f BSSID device wifi list ifname wlan0 | sed '/^$/d' | wc -l)"
    (( access_point_count > 0 )) || die "wlan0 completed a scan but detected no access points."

    printf 'SDIO ID:   %s\n' "$detected_id"
    printf 'Driver:    %s\n' "$detected_driver"
    printf 'Interface: wlan0\n'
    printf 'APs found: %s\n' "$access_point_count"
    echo "Wi-Fi verification passed."
}

log "Running board and hardware preflight"
preflight_board

if [[ "$MODE" == "verify" ]]; then
    verify_installation
    exit 0
fi

preflight_hardware
require_ethernet_link

[[ -r "$DRIVER_PATCH" ]] || die "missing driver patch: $DRIVER_PATCH"
[[ -r "$MODULES_FILE" ]] || die "missing module list: $MODULES_FILE"
command -v apt-get >/dev/null 2>&1 || die "an apt-based Debian/Ubuntu/Armbian system is required."
[[ -w /boot ]] || die "/boot is not writable."

export DEBIAN_FRONTEND=noninteractive

log "Installing build and Wi-Fi prerequisites"
apt-get update
apt-get install -y \
    build-essential \
    ca-certificates \
    device-tree-compiler \
    gcc-14 \
    git \
    iw \
    network-manager \
    patch \
    rfkill

readonly KERNEL_RELEASE="$(uname -r)"
readonly KERNEL_BUILD_DIR="/lib/modules/$KERNEL_RELEASE/build"
readonly MODULE_DESTINATION="/lib/modules/$KERNEL_RELEASE/extra/8189fs.ko"
readonly STOCK_DTB="/boot$STOCK_FDT"
readonly CUSTOM_DTB="/boot$CUSTOM_FDT"

[[ -d "$KERNEL_BUILD_DIR" ]] || die "matching headers are missing at $KERNEL_BUILD_DIR. Install them and rerun."
[[ -r "$STOCK_DTB" ]] || die "stock device tree is missing: $STOCK_DTB"

log "Preparing the pinned RTL8189FS source"
if [[ ! -e "$DRIVER_SOURCE_DIR" ]]; then
    git clone --branch rtl8189fs "$DRIVER_REPOSITORY_URL" "$DRIVER_SOURCE_DIR"
elif [[ ! -d "$DRIVER_SOURCE_DIR/.git" ]]; then
    die "$DRIVER_SOURCE_DIR exists but is not a Git checkout."
fi

if ! git -C "$DRIVER_SOURCE_DIR" cat-file -e "$DRIVER_COMMIT^{commit}" 2>/dev/null; then
    git -C "$DRIVER_SOURCE_DIR" fetch origin "$DRIVER_COMMIT"
fi

if [[ "$(git -C "$DRIVER_SOURCE_DIR" rev-parse HEAD)" != "$DRIVER_COMMIT" ]]; then
    if ! git -C "$DRIVER_SOURCE_DIR" diff --quiet || \
       ! git -C "$DRIVER_SOURCE_DIR" diff --cached --quiet; then
        die "$DRIVER_SOURCE_DIR has tracked changes on another commit; preserve or remove it before rerunning."
    fi
    git -C "$DRIVER_SOURCE_DIR" checkout --detach "$DRIVER_COMMIT"
fi

if git -C "$DRIVER_SOURCE_DIR" apply --check "$DRIVER_PATCH"; then
    git -C "$DRIVER_SOURCE_DIR" apply "$DRIVER_PATCH"
    echo "Applied the Linux 6.12 cfg80211 compatibility patch."
elif git -C "$DRIVER_SOURCE_DIR" apply --reverse --check "$DRIVER_PATCH"; then
    echo "The Linux 6.12 cfg80211 compatibility patch is already applied."
else
    die "the driver patch does not apply cleanly to $DRIVER_SOURCE_DIR."
fi

log "Building the driver for $KERNEL_RELEASE"
make -C "$DRIVER_SOURCE_DIR" clean
make -C "$DRIVER_SOURCE_DIR" \
    -j2 \
    CC=gcc-14 \
    ARCH=arm64 \
    KSRC="$KERNEL_BUILD_DIR"

built_vermagic="$(modinfo -F vermagic "$DRIVER_SOURCE_DIR/8189fs.ko")"
case "$built_vermagic" in
    "$KERNEL_RELEASE "*) ;;
    *) die "module vermagic '$built_vermagic' does not match $KERNEL_RELEASE." ;;
esac

log "Generating the corrected B860H device tree"
WORK_DIR="$(mktemp -d /tmp/setup-b860h-wifi.XXXXXX)"
base_dts="$WORK_DIR/meson-gxl-s905x-b860h.dts"
patched_dts="$WORK_DIR/meson-gxl-s905x-b860h-rtl8189fs.dts"
generated_dtb="$WORK_DIR/meson-gxl-s905x-b860h-rtl8189fs.dtb"

dtc -q -I dtb -O dts -o "$base_dts" "$STOCK_DTB"
if ! awk '
    /^[[:space:]]*sdio-pwrseq[[:space:]]*\{/ { in_node = 1 }
    in_node && /reset-gpios/ && /0x4c/ {
        sub(/0x4c/, "0x55")
        changed++
    }
    { print }
    in_node && /^[[:space:]]*};/ { in_node = 0 }
    END { if (changed != 1) exit 42 }
' "$base_dts" >"$patched_dts"; then
    die "expected exactly one 0x4c reset GPIO in the sdio-pwrseq node."
fi

dtc -q -I dts -O dtb -o "$generated_dtb" "$patched_dts"
if ! dtc -q -I dtb -O dts "$generated_dtb" 2>/dev/null \
    | awk '
        /^[[:space:]]*sdio-pwrseq[[:space:]]*\{/ { in_node = 1 }
        in_node && /reset-gpios/ && /0x55/ { found++ }
        in_node && /^[[:space:]]*};/ { in_node = 0 }
        END { exit(found == 1 ? 0 : 1) }
    '; then
    die "generated DTB does not contain the expected GPIOX_6 reset offset."
fi

log "Backing up boot files and installing staged artifacts"
backup_timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="/root/rtl8189fs-backup/$backup_timestamp"
install -d -o root -g root -m 0700 "$backup_dir"
cp -a "$UENV_FILE" "$backup_dir/uEnv.txt"
cp -a "$STOCK_DTB" "$backup_dir/"
test -e /boot/uEnv.txt.pre-rtl8189fs || cp -a "$UENV_FILE" /boot/uEnv.txt.pre-rtl8189fs

install -D -m 0644 "$DRIVER_SOURCE_DIR/8189fs.ko" "$MODULE_DESTINATION"
install -m 0644 "$generated_dtb" "$CUSTOM_DTB"
install -D -m 0644 "$MODULES_FILE" "$MODULES_LOAD_FILE"
depmod -a

uenv_staged="$WORK_DIR/uEnv.txt"
if ! awk -v custom_fdt="$CUSTOM_FDT" '
    /^FDT=/ {
        print "FDT=" custom_fdt
        changed++
        next
    }
    { print }
    END { if (changed != 1) exit 42 }
' "$UENV_FILE" >"$uenv_staged"; then
    die "$UENV_FILE must contain exactly one FDT= line."
fi
install -o root -g root -m 0644 "$uenv_staged" "$UENV_FILE"

systemctl enable NetworkManager.service
sync

log "Installation staged successfully"
printf 'Backup:       %s\n' "$backup_dir"
printf 'Module:       %s\n' "$MODULE_DESTINATION"
printf 'Custom DTB:   %s\n' "$CUSTOM_DTB"
printf 'Boot selector: FDT=%s\n' "$CUSTOM_FDT"
sha256sum "$MODULE_DESTINATION" "$CUSTOM_DTB"

cat <<EOF

The update becomes active after reboot.

After reboot, verify it with:
  sudo bash $0 --verify

To connect wlan0 after verification:
  nmtui

Rollback from a working shell:
  cp -a /boot/uEnv.txt.pre-rtl8189fs /boot/uEnv.txt
  sync
  reboot
EOF

if [[ "$REBOOT_AFTER_INSTALL" == true ]]; then
    log "Rebooting"
    reboot
else
    echo
    echo "Reboot when ready: reboot"
fi
