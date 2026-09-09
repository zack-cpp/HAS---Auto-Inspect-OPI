#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly KERNEL_RELEASE="$(uname -r)"
readonly INSTALLER="$REPOSITORY_DIR/firmware/b860h-rtl8189fs/$KERNEL_RELEASE/install.sh"

if [[ ! -r "$INSTALLER" ]]; then
    echo "Error: no precompiled B860H Wi-Fi bundle for kernel $KERNEL_RELEASE." >&2
    echo "Expected installer: $INSTALLER" >&2
    exit 1
fi

exec bash "$INSTALLER" "$@"
