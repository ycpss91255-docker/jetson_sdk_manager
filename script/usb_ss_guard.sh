#!/usr/bin/env bash
# usb_ss_guard.sh — disable the SuperSpeed half of the Jetson's USB-C
# connector on the host for the initrd flash (#100). Skeleton: usage only.

set -euo pipefail

case "${1:-}" in
  *) printf 'Usage: %s {disable|enable|status|auto [timeout]}\n' "$0" >&2; exit 2 ;;
esac
