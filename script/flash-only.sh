#!/usr/bin/env bash
# Phase 2 of two-phase flash: write pre-built images to Jetson.
#
# Usage:
#   flash-only.sh [--target BOARD] [--storage TYPE]
#
# Defaults:
#   --target jetson-agx-orin-devkit
#   --storage external
#
# Prerequisites:
#   - Images already built via flash-build.sh
#   - Jetson in clean APX recovery mode (full power cycle + Recovery
#     button — a software reboot to recovery is not sufficient)

set -euo pipefail

TARGET="jetson-agx-orin-devkit"
STORAGE="external"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  TARGET="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

L4T_DIR=$(find "${HOME}/nvidia/nvidia_sdk" -maxdepth 3 -type d -name "Linux_for_Tegra" | head -1)
if [[ -z "$L4T_DIR" ]]; then
    echo "ERROR: Linux_for_Tegra not found under \$HOME/nvidia/nvidia_sdk" >&2
    exit 1
fi

IMG_DIR="$L4T_DIR/tools/kernel_flash/images"
if [[ ! -d "$IMG_DIR/internal" || ! -d "$IMG_DIR/external" ]]; then
    echo "ERROR: pre-built images missing at $IMG_DIR/{internal,external}." >&2
    echo "Run flash-build.sh first." >&2
    exit 1
fi

cd "$L4T_DIR"
exec sudo -E USER=root ./tools/kernel_flash/l4t_initrd_flash.sh \
    --flash-only \
    --showlogs \
    "$TARGET" "$STORAGE"
