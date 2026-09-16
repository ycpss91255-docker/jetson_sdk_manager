#!/usr/bin/env bash
# usb.sh — Jetson USB recovery-device detection helpers.
#
# Centralizes the NVIDIA vendor / Tegra recovery PID list so both
# `script/flash.sh` (pre-flight check before writing) and
# `script/probe.sh` (standalone diagnostic) read the same authoritative
# set. PIDs come from /usr/share/sdkmanager/Assets/Manifest.json on the
# cli/gui image; extend the list when a new SKU ships.

set -euo pipefail

# NVIDIA Corp. USB-IF vendor ID. Stable across all Jetson SKUs.
JETSON_USB_VENDOR='0955'

# Tegra recovery (APX) product IDs across the Orin family. ECID-level
# match happens later inside tegrarcm_v2 — this list only answers "is
# any Jetson on the bus in recovery right now?".
JETSON_RECOVERY_PIDS=('7023' '7223' '7423' '7523' '7e19')

# Booted L4T device-mode PID. After a successful flash the Jetson reboots
# and re-enumerates as this — its usb0 gadget now runs a DHCP server
# (192.168.55.1) and you WANT NetworkManager managing the host side again.
# nm_flash_guard.sh's auto mode watches for this PID to flip NM back on.
JETSON_BOOTED_PID='7020'

# Flash-initrd device-mode PID. During l4t_initrd_flash the board leaves RCM
# and re-enumerates as this (RNDIS gadget, "Linux for Tegra") until the
# flash finishes and it reboots into JETSON_BOOTED_PID. usb_ss_guard.sh
# anchors on it when the guard is applied mid-flash (#100).
# shellcheck disable=SC2034  # consumed by usb_ss_guard.sh, not in this file
JETSON_INITRD_PID='7035'

# ── usb_ss_guard.sh state (#100) ─────────────────────────────────────
# Shared between usb_ss_guard.sh (writes) and lib/status.sh (reads), so the
# defaults and the path check exist exactly once.
#
# The guard records which usb_port it disabled so `enable` can restore it,
# and `enable` writes to that recorded path as root — so the record must
# not be forgeable. It lives in a root-owned directory under /run (tmpfs,
# cleared on boot like the sysfs setting itself; nobody but root can
# pre-create /run/usb-ss-guard), and the path is re-validated on every use.
USB_SYSFS="${USB_SYSFS:-/sys/bus/usb/devices}"
USB_SS_GUARD_STATE_DIR="${USB_SS_GUARD_STATE_DIR:-/run/usb-ss-guard}"

# usb_ss_state_port <state file>
# Prints the `port=` value of a guard state file (empty when absent).
usb_ss_state_port() {
  sed -n 's/^port=//p' "$1" 2>/dev/null | head -n1
}

# usb_ss_port_ok <port dir>
# Returns 0 only for a root-hub usb_port directory the guard may write to:
#   <USB_SYSFS>/usbN/N-0:1.0/usbN-portM   (all three N equal)
# whose directory and `disable` attribute exist, are not symlinks, and
# whose canonical path is exactly that of the root hub's canonical
# directory plus the same trailing components — i.e. nothing in the tail
# is a link pointing somewhere else. (The usbN entry itself IS a symlink
# in the real sysfs, which is why the prefix is compared canonically.)
usb_ss_port_ok() {
  local port="$1" rel hub iface pname n1 n2 n3 m canon_hub
  [[ -n "${port}" && "${port}" == "${USB_SYSFS}/"* ]] || return 1
  rel="${port#"${USB_SYSFS}"/}"
  [[ "${rel}" =~ ^usb([0-9]+)/([0-9]+)-0:1\.0/usb([0-9]+)-port([0-9]+)$ ]] || return 1
  n1="${BASH_REMATCH[1]}"; n2="${BASH_REMATCH[2]}"; n3="${BASH_REMATCH[3]}"; m="${BASH_REMATCH[4]}"
  [[ "${n1}" == "${n2}" && "${n1}" == "${n3}" ]] || return 1
  hub="${USB_SYSFS}/usb${n1}"; iface="${n1}-0:1.0"; pname="usb${n1}-port${m}"
  [[ -d "${port}" && ! -L "${port}" ]] || return 1
  [[ -f "${port}/disable" && ! -L "${port}/disable" ]] || return 1
  canon_hub="$(readlink -f "${hub}" 2>/dev/null)" || return 1
  [[ -n "${canon_hub}" ]] || return 1
  [[ "$(readlink -f "${port}/disable" 2>/dev/null)" == "${canon_hub}/${iface}/${pname}/disable" ]]
}

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

# jetson_is_booted_l4t
# Returns 0 if a Jetson that has finished flashing and booted into the OS
# device-mode (JETSON_BOOTED_PID) is on the USB bus. nm_flash_guard.sh
# auto mode polls this to know when to hand usb0 back to NetworkManager.
jetson_is_booted_l4t() {
  lsusb -d "${JETSON_USB_VENDOR}:${JETSON_BOOTED_PID}" 2>/dev/null | grep -q .
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
