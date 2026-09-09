#!/usr/bin/env bash

set -Eeuo pipefail

readonly BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly EXPECTED_BOARD_COMPATIBLE="zte,b860h"
readonly EXPECTED_ARCHITECTURE="arm64"
readonly EXPECTED_SDIO_ID="024C:F179"
readonly EXPECTED_KERNEL_RELEASE="6.12.103-ophub"
readonly EXPECTED_KERNEL_SHA256="9d3021819a895e3487627a0bc536744c75fde6470318aef782f7d56743ef000b"
readonly EXPECTED_STOCK_DTB_SHA256="3de0713a52f63651338a4b4416701e5f9b583453acb8cbff74427ce743757515"
readonly EXPECTED_MODULE_VERMAGIC="6.12.103-ophub SMP preempt mod_unload aarch64"
readonly STOCK_FDT="/dtb/amlogic/meson-gxl-s905x-b860h.dtb"
readonly CUSTOM_FDT="/dtb/amlogic/meson-gxl-s905x-b860h-rtl8189fs.dtb"
readonly STOCK_DTB="/boot$STOCK_FDT"
readonly CUSTOM_DTB="/boot$CUSTOM_FDT"
readonly UENV_FILE="/boot/uEnv.txt"
readonly UENV_BACKUP="/boot/uEnv.txt.pre-rtl8189fs"
readonly MODULE_SOURCE="$BUNDLE_DIR/8189fs.ko"
readonly DTB_SOURCE="$BUNDLE_DIR/meson-gxl-s905x-b860h-rtl8189fs.dtb"
readonly MODULES_SOURCE="$BUNDLE_DIR/8189fs.conf"
readonly MODULE_DESTINATION="/lib/modules/$EXPECTED_KERNEL_RELEASE/extra/8189fs.ko"
readonly MODULES_DESTINATION="/etc/modules-load.d/8189fs.conf"

MODE="install"
CONFIRM_HARDWARE=false
REBOOT_AFTER_ACTION=false
WORK_DIR=""

usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Installs this precompiled RTL8189FS bundle without compiling or downloading.

Options:
  --confirm-hardware  Assert that an unenumerated radio was physically verified
                      as RTL8189FTV/RTL8189FS with GPIOX_6 wiring.
  --reboot            Reboot after a successful install or rollback.
  --check             Validate the target and bundle without installing.
  --verify            Verify the active installation without changing it.
  --rollback          Restore the preserved pre-install boot configuration.
  -h, --help          Show this help text.
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
        rm -f -- "$WORK_DIR/uEnv.txt"
        rmdir -- "$WORK_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT

while (( $# > 0 )); do
    case "$1" in
        --confirm-hardware) CONFIRM_HARDWARE=true ;;
        --reboot) REBOOT_AFTER_ACTION=true ;;
        --check) MODE="check" ;;
        --verify) MODE="verify" ;;
        --rollback) MODE="rollback" ;;
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
if [[ "$MODE" =~ ^(check|verify)$ && "$REBOOT_AFTER_ACTION" == true ]]; then
    die "--$MODE and --reboot cannot be used together."
fi

read_compatible_strings() {
    tr '\0' '\n' </proc/device-tree/compatible
}

read_active_fdt() {
    awk '
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

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

preflight_board() {
    local active_fdt
    local architecture
    local kernel_release

    [[ -r /proc/device-tree/compatible ]] || die "device-tree compatible data is unavailable."
    if ! read_compatible_strings | grep -Fxq "$EXPECTED_BOARD_COMPATIBLE"; then
        echo "Detected compatible strings:" >&2
        read_compatible_strings >&2
        die "this bundle only supports $EXPECTED_BOARD_COMPATIBLE."
    fi

    architecture="$(dpkg --print-architecture 2>/dev/null || true)"
    [[ "$architecture" == "$EXPECTED_ARCHITECTURE" ]] || \
        die "expected $EXPECTED_ARCHITECTURE, detected '${architecture:-unknown}'."

    kernel_release="$(uname -r)"
    [[ "$kernel_release" == "$EXPECTED_KERNEL_RELEASE" ]] || \
        die "bundle requires $EXPECTED_KERNEL_RELEASE, detected $kernel_release."

    [[ -r "$UENV_FILE" ]] || die "$UENV_FILE is missing or unreadable."
    active_fdt="$(read_active_fdt)" || \
        die "$UENV_FILE must contain exactly one non-empty FDT= line."
    case "$active_fdt" in
        "$STOCK_FDT"|"$CUSTOM_FDT") ;;
        *) die "unsupported active FDT '$active_fdt'." ;;
    esac

    printf 'Board:        %s\n' "$(tr -d '\0' </proc/device-tree/model)"
    printf 'Compatible:   %s\n' "$EXPECTED_BOARD_COMPATIBLE"
    printf 'Architecture: %s\n' "$architecture"
    printf 'Kernel:       %s\n' "$kernel_release"
    printf 'Active FDT:   %s\n' "$active_fdt"
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

    [[ "$found_other" != true ]] || \
        die "a non-$EXPECTED_SDIO_ID SDIO device is present; refusing this bundle."
    if [[ "$found_expected" == true ]]; then
        return
    fi
    if [[ "$CONFIRM_HARDWARE" != true ]]; then
        cat >&2 <<EOF
No SDIO identity is visible. The stock DTB can leave the radio unpowered, but
B860H revisions also contain other chipsets. Physically verify RTL8189FTV/
RTL8189FS and GPIOX_6 wiring, then rerun with --confirm-hardware.
EOF
        exit 1
    fi
    echo "Proceeding on the operator's explicit hardware confirmation."
}

require_ethernet_link() {
    local interface_path

    for interface_path in /sys/class/net/eth*; do
        [[ -e "$interface_path/operstate" ]] || continue
        if [[ "$(<"$interface_path/operstate")" == "up" ]]; then
            printf 'Ethernet:     %s is up\n' "${interface_path##*/}"
            return
        fi
    done
    die "no active Ethernet recovery path was found."
}

verify_file_hash() {
    local expected_hash="$1"
    local file="$2"
    local actual_hash

    [[ -r "$file" ]] || die "required file is missing: $file"
    actual_hash="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || \
        die "checksum mismatch for $file: expected $expected_hash, got $actual_hash."
}

verify_bundle() {
    local module_vermagic

    log "Verifying bundle integrity and target image"
    (cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS)
    verify_file_hash "$EXPECTED_KERNEL_SHA256" /boot/zImage
    verify_file_hash "$EXPECTED_STOCK_DTB_SHA256" "$STOCK_DTB"

    module_vermagic="$(modinfo -F vermagic "$MODULE_SOURCE")"
    [[ "$module_vermagic" == "$EXPECTED_MODULE_VERMAGIC" ]] || \
        die "module vermagic mismatch: '$module_vermagic'."
}

verify_running_installation() {
    local access_point_count
    local detected_driver=""
    local detected_id=""
    local uevent

    log "Verifying the running Wi-Fi installation"
    [[ "$(read_active_fdt)" == "$CUSTOM_FDT" ]] || \
        die "the corrected device tree is not active."

    for uevent in /sys/bus/sdio/devices/*/uevent; do
        [[ -e "$uevent" ]] || continue
        if grep -Fxq "SDIO_ID=$EXPECTED_SDIO_ID" "$uevent"; then
            detected_id="$(sed -n 's/^SDIO_ID=//p' "$uevent")"
            detected_driver="$(sed -n 's/^DRIVER=//p' "$uevent")"
            break
        fi
    done

    [[ "$detected_id" == "$EXPECTED_SDIO_ID" ]] || \
        die "SDIO device $EXPECTED_SDIO_ID is not enumerated."
    [[ "$detected_driver" == "rtl8189fs" ]] || \
        die "SDIO device is not bound to rtl8189fs."
    grep -q '^8189fs ' /proc/modules || die "8189fs is not loaded."
    grep -q '^cfg80211 ' /proc/modules || die "cfg80211 is not loaded."
    [[ -d /sys/class/net/wlan0 ]] || die "wlan0 is missing."
    systemctl is-active --quiet NetworkManager.service || \
        die "NetworkManager is not active."

    if rfkill list wifi | grep -Eq 'Soft blocked: yes|Hard blocked: yes'; then
        rfkill list wifi >&2
        die "Wi-Fi is blocked by rfkill."
    fi

    nmcli device wifi rescan ifname wlan0
    access_point_count="$(nmcli -t -f BSSID device wifi list ifname wlan0 \
        | sed '/^$/d' | wc -l)"
    (( access_point_count > 0 )) || die "no access points were detected."

    printf 'SDIO ID:     %s\n' "$detected_id"
    printf 'Driver:      %s\n' "$detected_driver"
    printf 'Interface:   wlan0\n'
    printf 'APs found:   %s\n' "$access_point_count"
    echo "Wi-Fi verification passed."
}

for required_command in awk dpkg grep install modinfo sed sha256sum systemctl; do
    require_command "$required_command"
done

log "Running target preflight"
preflight_board

if [[ "$MODE" == "verify" ]]; then
    for required_command in nmcli rfkill; do
        require_command "$required_command"
    done
    verify_running_installation
    exit 0
fi

if [[ "$MODE" == "rollback" ]]; then
    [[ -r "$UENV_BACKUP" ]] || die "rollback file is missing: $UENV_BACKUP"
    cp -a "$UENV_BACKUP" "$UENV_FILE"
    sync
    echo "Restored $UENV_FILE from $UENV_BACKUP."
    if [[ "$REBOOT_AFTER_ACTION" == true ]]; then
        reboot
    else
        echo "Reboot when ready: reboot"
    fi
    exit 0
fi

preflight_hardware
[[ -w /boot ]] || die "/boot is not writable."
verify_bundle

if [[ "$MODE" == "check" ]]; then
    echo "Target and precompiled bundle validation passed; no changes were made."
    exit 0
fi

require_ethernet_link

log "Backing up boot files"
backup_timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="/root/rtl8189fs-backup/$backup_timestamp"
install -d -o root -g root -m 0700 "$backup_dir"
cp -a "$UENV_FILE" "$backup_dir/uEnv.txt"
cp -a "$STOCK_DTB" "$backup_dir/"
test -e "$UENV_BACKUP" || cp -a "$UENV_FILE" "$UENV_BACKUP"

log "Installing precompiled module and device tree"
install -D -m 0644 "$MODULE_SOURCE" "$MODULE_DESTINATION"
install -m 0644 "$DTB_SOURCE" "$CUSTOM_DTB"
install -D -m 0644 "$MODULES_SOURCE" "$MODULES_DESTINATION"
depmod -a "$EXPECTED_KERNEL_RELEASE"

WORK_DIR="$(mktemp -d /tmp/install-b860h-wifi-bundle.XXXXXX)"
if ! awk -v custom_fdt="$CUSTOM_FDT" '
    /^FDT=/ {
        print "FDT=" custom_fdt
        changed++
        next
    }
    { print }
    END { if (changed != 1) exit 42 }
' "$UENV_FILE" >"$WORK_DIR/uEnv.txt"; then
    die "$UENV_FILE must contain exactly one FDT= line."
fi
install -o root -g root -m 0644 "$WORK_DIR/uEnv.txt" "$UENV_FILE"
systemctl enable NetworkManager.service
sync

log "Offline installation staged successfully"
printf 'Backup:        %s\n' "$backup_dir"
printf 'Module:        %s\n' "$MODULE_DESTINATION"
printf 'Custom DTB:    %s\n' "$CUSTOM_DTB"
printf 'Boot selector: FDT=%s\n' "$CUSTOM_FDT"
sha256sum "$MODULE_DESTINATION" "$CUSTOM_DTB"

cat <<EOF

After reboot, run:
  sudo bash $0 --verify

Rollback if needed:
  sudo bash $0 --rollback --reboot
EOF

if [[ "$REBOOT_AFTER_ACTION" == true ]]; then
    log "Rebooting"
    reboot
else
    echo
    echo "Reboot when ready: reboot"
fi
