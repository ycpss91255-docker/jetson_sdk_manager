#!/usr/bin/env bash
# Phase 1 of two-phase flash: generate images, no Jetson interaction.
#
# Usage:
#   flash-build.sh [--external-device DEV] [--config CFG] [--target BOARD]
#
# Defaults:
#   --external-device sda1
#   --config tools/kernel_flash/flash_l4t_external.xml
#   --target jetson-agx-orin-devkit
#
# Generated images land in
#   $L4T/tools/kernel_flash/images/{internal,external}/
# which is volume-mounted to host data/nvidia_sdk/...; the container
# can be destroyed afterwards without losing them. Reuse them with
# flash-only.sh.

set -euo pipefail

EXTERNAL_DEVICE="sda1"
CONFIG="tools/kernel_flash/flash_l4t_external.xml"
TARGET="jetson-agx-orin-devkit"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --external-device) EXTERNAL_DEVICE="$2"; shift 2 ;;
        --config|-c)       CONFIG="$2"; shift 2 ;;
        --target)          TARGET="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

L4T_DIR=$(find "${HOME}/nvidia/nvidia_sdk" -maxdepth 3 -type d -name "Linux_for_Tegra" | head -1)
if [[ -z "$L4T_DIR" ]]; then
    echo "ERROR: Linux_for_Tegra not found under \$HOME/nvidia/nvidia_sdk" >&2
    exit 1
fi

cd "$L4T_DIR"
exec sudo -E USER=root ./tools/kernel_flash/l4t_initrd_flash.sh \
    --no-flash \
    --external-device "$EXTERNAL_DEVICE" \
    -c "$CONFIG" \
    --showlogs \
    "$TARGET" external
