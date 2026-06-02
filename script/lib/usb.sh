#!/usr/bin/env bash
# usb.sh — Jetson USB recovery-device detection helpers.
#
# Centralizes the NVIDIA vendor / Tegra recovery PID list so both
# `script/flash.sh` (pre-flight check before writing) and
# `script/probe.sh` (standalone diagnostic) read the same authoritative
# set. PIDs come from /usr/share/sdkmanager/Assets/Manifest.json on the
# inspector image; extend the list when a new SKU ships.

set -euo pipefail

# NVIDIA Corp. USB-IF vendor ID. Stable across all Jetson SKUs.
JETSON_USB_VENDOR='0955'

# Tegra recovery (APX) product IDs across the Orin family. ECID-level
# match happens later inside tegrarcm_v2 — this list only answers "is
# any Jetson on the bus in recovery right now?".
JETSON_RECOVERY_PIDS=('7023' '7223' '7423' '7523' '7e19')

# jetson_pid_is_recovery <pid>
# Echoes nothing; returns 0 when the PID is in the recovery list.
# Case-folds the input so an uppercase hex PID (e.g. 7E19 from some
# lsusb builds) still matches the lowercase JETSON_RECOVERY_PIDS list.
jetson_pid_is_recovery() {
  local pid="${1,,}" candidate
  for candidate in "${JETSON_RECOVERY_PIDS[@]}"; do
    [[ "${candidate}" == "${pid}" ]] && return 0
  done
  return 1
}

# jetson_in_recovery
# Returns 0 if any of the known recovery PIDs is on the USB bus.
# Used by flash.sh as a hard gate before invoking l4t_initrd_flash.
jetson_in_recovery() {
  local pid
  for pid in "${JETSON_RECOVERY_PIDS[@]}"; do
    if lsusb -d "${JETSON_USB_VENDOR}:${pid}" 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

# jetson_list_devices
# Echoes one line per NVIDIA-vendor USB device currently on the bus:
#   "<pid>\t<lsusb line>"
# Empty output means no NVIDIA device is attached. Caller decides how
# to react (recovery-PID check, summary print, etc.).
jetson_list_devices() {
  local line pid
  while IFS= read -r line; do
    pid=$(printf '%s' "${line}" | awk '{print $6}' | cut -d: -f2)
    printf '%s\t%s\n' "${pid}" "${line}"
  done < <(lsusb -d "${JETSON_USB_VENDOR}:" 2>/dev/null)
}
