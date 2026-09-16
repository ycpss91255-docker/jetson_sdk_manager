#!/usr/bin/env bash
# usb_ss_guard.sh — disable the SuperSpeed half of the Jetson's USB-C
# connector on the host while the initrd flash runs (#100).
#
# A USB-C / USB 3 connector is two links: a high-speed (USB 2) pair and a
# SuperSpeed (USB 3) pair, which the kernel exposes as two ports on two
# different xHCI root hubs that share the same ACPI `location`. RCM and the
# flash initrd's RNDIS gadget (0955:7035) only need the high-speed half —
# but the gadget also tries to train a SuperSpeed link, and on some hosts
# that link never comes up. The xHCI SS root hub then retries forever:
#
#   usb 2-3: device not accepting address 17, error -71
#   usb usb2-port3: Cannot enable. Maybe the USB cable is bad?   (every 4 s)
#   usb 3-1: New USB device found, idVendor=0955, idProduct=7035
#   usb 3-1: USB disconnect, device number 71                     (same second)
#
# and every retry tears the working high-speed device down with it, so
# l4t_initrd_flash waits for a target that keeps vanishing. Turning the SS
# port off (`echo 1 > .../usbN-portM/disable`) leaves the HS half alone and
# the board stays enumerated. The setting is sysfs, boot-scoped, and
# reversed with `echo 0` — hence a flash-scoped guard like nm_flash_guard.sh.
#
# Usage:
#   ./script/usb_ss_guard.sh disable        # before `make run -- -t flash`
#   ./script/usb_ss_guard.sh enable         # after flashing (or leave it to auto)
#   ./script/usb_ss_guard.sh auto [timeout] # disable, then re-enable the moment
#                                           # the board boots (0955:7020), or after
#                                           # <timeout>s (default 1800)
#   ./script/usb_ss_guard.sh status
#
# Paths are overridable so the bats suite can drive every branch against a
# fixture tree without root or hardware.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"

USB_SYSFS="${USB_SYSFS:-/sys/bus/usb/devices}"
# What `disable` turned off, so `enable` restores exactly that and nothing
# else. Lives in /tmp on purpose: the sysfs setting is boot-scoped and so is
# the record of it.
STATE_FILE="${USB_SS_GUARD_STATE:-/tmp/usb-ss-guard.state}"
# Auto-mode watcher bookkeeping (same shape as nm_flash_guard.sh).
WATCH_PIDFILE="${USB_SS_GUARD_PIDFILE:-/tmp/usb-ss-guard.pid}"
POLL_INTERVAL="${USB_SS_GUARD_POLL_INTERVAL:-3}"
AUTO_TIMEOUT_DEFAULT="${USB_SS_GUARD_TIMEOUT:-1800}"

_step() { printf '\n\033[36m[usb-ss-guard] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }
_warn() { printf '  %s\n' "$1" >&2; }

_sudo_noninteractive_ok() { sudo -n true 2>/dev/null; }

# _attr <dir> <name> — first line of a sysfs attribute, empty when unreadable.
_attr() { head -n1 "$1/$2" 2>/dev/null || true; }

# _jetson_dev — the sysfs directory (basename, e.g. 3-1 or 2-1.4) of the
# Jetson to anchor on: a board in recovery, or — for a flash already in
# progress — the initrd flash device. Prints nothing when neither is there.
_jetson_dev() {
  local d vid pid fallback=""
  for d in "${USB_SYSFS}"/*/; do
    d="${d%/}"
    [[ "${d##*/}" == *:* ]] && continue          # interfaces, not devices
    vid="$(_attr "${d}" idVendor)"
    [[ "${vid,,}" == "${JETSON_USB_VENDOR}" ]] || continue
    pid="$(_attr "${d}" idProduct)"
    if jetson_pid_is_recovery "${pid}"; then
      printf '%s\n' "${d##*/}"; return 0
    elif [[ "${pid,,}" == "${JETSON_INITRD_PID}" && -z "${fallback}" ]]; then
      fallback="${d##*/}"
    fi
  done
  [[ -n "${fallback}" ]] && printf '%s\n' "${fallback}"
  return 0
}

# _port_of <dev> — the usb_port directory a device hangs off, derived from
# its name: N-M sits on root hub usbN, port M → N-0:1.0/usbN-portM; a device
# behind a hub, N-M.X, sits on hub N-M, port X → N-M:1.0/N-M-portX. (Newer
# kernels also give the device a `port` symlink; the name works everywhere.)
_port_of() {
  local dev="$1" bus="${1%%-*}" path="${1#*-}"
  if [[ "${path}" != *.* ]]; then
    printf '%s/%s-0:1.0/usb%s-port%s\n' "${USB_SYSFS}" "${bus}" "${bus}" "${path}"
  else
    printf '%s/%s-%s:1.0/%s-%s-port%s\n' "${USB_SYSFS}" "${bus}" "${path%.*}" "${bus}" "${path%.*}" "${path##*.}"
  fi
}

# _peer_of <port dir> — the other usb_port with the same non-zero ACPI
# location: the SuperSpeed half of the same physical connector. Ports the
# firmware did not describe (downstream hubs) report 0x00000000 and are
# never paired. Prints nothing when there is no sibling.
_peer_of() {
  local port="$1" loc cand cloc
  loc="$(_attr "${port}" location)"
  [[ -n "${loc}" ]] || return 0
  [[ "${loc}" =~ ^0x0*$ ]] && return 0
  for cand in "${USB_SYSFS}"/*:1.0/*-port*/; do
    cand="${cand%/}"
    [[ "${cand}" == "${port}" ]] && continue
    cloc="$(_attr "${cand}" location)"
    if [[ "${cloc}" == "${loc}" ]]; then
      printf '%s\n' "${cand}"; return 0
    fi
  done
  return 0
}

# _write_disable <port dir> <0|1> — via sudo tee (sysfs is root-only), then
# read back: a write that did not take is a failure, not a silent "ok".
_write_disable() {
  printf '%s\n' "$2" | sudo tee "$1/disable" >/dev/null 2>&1 || true
  [[ "$(_attr "$1" disable)" == "$2" ]]
}

disable() {
  _step "Disabling the SuperSpeed half of the Jetson's USB connector (flash mode)"
  local dev port peer loc
  if [[ -f "${STATE_FILE}" ]]; then
    peer="$(head -n1 "${STATE_FILE}")"
    if [[ "$(_attr "${peer}" disable)" == "1" ]]; then
      _ok "${peer##*/} already disabled (recorded in ${STATE_FILE})"
      return 0
    fi
  fi
  dev="$(_jetson_dev)"
  if [[ -z "${dev}" ]]; then
    _warn "no Jetson in recovery (0955:${JETSON_RECOVERY_PIDS[0]}…) or initrd flash (0955:${JETSON_INITRD_PID}) on the USB bus — nothing to guard"
    return 0
  fi
  port="$(_port_of "${dev}")"
  if [[ ! -d "${port}" ]]; then
    _warn "Jetson is ${dev} but its port ${port##*/} is not in ${USB_SYSFS} — nothing to guard"
    return 0
  fi
  loc="$(_attr "${port}" location)"
  peer="$(_peer_of "${port}")"
  if [[ -z "${peer}" ]]; then
    _warn "Jetson ${dev} is on ${port##*/} (location ${loc:-?}) and it has no SuperSpeed sibling — USB-2-only cable or a hub? nothing to disable"
    return 0
  fi
  if [[ ! -e "${peer}/disable" ]]; then
    _warn "${peer##*/} is the SuperSpeed half of ${port##*/} (location ${loc}) but this kernel exposes no 'disable' attribute for it — cannot guard; if the flash loops on 'Cannot enable', try a different port or host"
    return 0
  fi
  if ! _write_disable "${peer}" 1; then
    printf '  error: could not write 1 to %s/disable (sudo?) — run: echo 1 | sudo tee %s/disable\n' "${peer}" "${peer}" >&2
    return 1
  fi
  printf '%s\n' "${peer}" > "${STATE_FILE}"
  _ok "Jetson ${dev} is on ${port##*/}; disabled its SuperSpeed sibling ${peer##*/} (location ${loc}) — the high-speed link stays up"
}

enable() {
  _step "Re-enabling the SuperSpeed half of the Jetson's USB connector (normal mode)"
  local peer
  if [[ ! -f "${STATE_FILE}" ]]; then
    _warn "no state file (${STATE_FILE}) — nothing to re-enable"
    return 0
  fi
  peer="$(head -n1 "${STATE_FILE}")"
  if [[ ! -d "${peer}" ]]; then
    _warn "${peer} recorded but gone from sysfs (reboot?) — dropping the state file"
    rm -f "${STATE_FILE}"
    return 0
  fi
  if ! _write_disable "${peer}" 0; then
    # The detached auto watcher may not be able to sudo (no tty). Keep the
    # state so a later `enable` (or host_teardown.sh) still knows the port.
    printf '  error: could not re-enable %s (sudo needs a tty?) — run: echo 0 | sudo tee %s/disable\n' \
      "${peer##*/}" "${peer}" >&2
    return 1
  fi
  rm -f "${STATE_FILE}"
  _ok "${peer##*/} enabled again — the connector is back to USB 3"
}

status() {
  _step "USB SuperSpeed flash-guard status"
  local peer
  if [[ -f "${STATE_FILE}" ]]; then
    peer="$(head -n1 "${STATE_FILE}")"
    printf '  DISABLED (flash mode): %s (disable=%s), recorded in %s\n' \
      "${peer##*/}" "$(_attr "${peer}" disable)" "${STATE_FILE}" >&2
  else
    printf '  ENABLED (normal mode): no port disabled by this guard\n' >&2
  fi
  if [[ -e "${WATCH_PIDFILE}.failed" ]]; then
    printf '  AUTO watcher could not re-enable the port — %s' \
      "$(cat "${WATCH_PIDFILE}.failed" 2>/dev/null)" >&2
  elif [[ -e "${WATCH_PIDFILE}" ]] && kill -0 "$(cat "${WATCH_PIDFILE}" 2>/dev/null)" 2>/dev/null; then
    printf '  AUTO watcher running (PID %s) — will re-enable on boot (0955:%s)\n' \
      "$(cat "${WATCH_PIDFILE}")" "${JETSON_BOOTED_PID}" >&2
  elif [[ -e "${WATCH_PIDFILE}" ]]; then
    printf '  AUTO watcher pidfile present but the process is dead — if the port is still off, run: %s enable\n' \
      "${BASH_SOURCE[0]}" >&2
  fi
}

# _reenable_or_mark — re-enable and clear watcher state; on failure leave a
# `.failed` marker so `status` can report it (the detached watcher's output
# goes nowhere).
_reenable_or_mark() {
  if enable; then
    rm -f "${WATCH_PIDFILE}" "${WATCH_PIDFILE}.failed" 2>/dev/null || true
  else
    printf 'could not re-enable the SuperSpeed port (sudo needs a tty?). Run: %s enable\n' \
      "${BASH_SOURCE[0]}" > "${WATCH_PIDFILE}.failed" 2>/dev/null || true
    rm -f "${WATCH_PIDFILE}" 2>/dev/null || true
  fi
}

# _watch <timeout> — poll the USB bus; re-enable the port the moment the
# board boots (JETSON_BOOTED_PID), or unconditionally after <timeout>
# seconds so an aborted flash never leaves the connector at USB 2.
_watch() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}" waited=0
  while (( waited < timeout )); do
    if jetson_is_booted_l4t; then
      _step "Jetson booted (0955:${JETSON_BOOTED_PID}) — re-enabling the SuperSpeed port"
      _reenable_or_mark
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done
  _step "Auto watcher timed out after ${timeout}s — re-enabling the SuperSpeed port so it isn't left off"
  _reenable_or_mark
}

# auto [timeout] — disable now, then background a watcher that restores the
# port as soon as the board boots. Nothing disabled → no watcher.
auto() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}"
  disable
  if [[ ! -f "${STATE_FILE}" ]]; then
    _ok "nothing disabled — no watcher needed"
    return 0
  fi
  # The watcher is detached (no tty): on tty_tickets sudo hosts its re-enable
  # will fail. Less harmful than the NM case (the connector merely stays at
  # USB 2 until `enable`, teardown or a reboot), but say so.
  if ! _sudo_noninteractive_ok; then
    _warn "heads-up: sudo needs a password here, so the background watcher may not re-enable the port after boot — run '${BASH_SOURCE[0]} enable' (host_teardown.sh does) or reboot"
  fi
  _step "Starting auto watcher (re-enable on boot 0955:${JETSON_BOOTED_PID}, or after ${timeout}s)"
  setsid bash "${BASH_SOURCE[0]}" _watch "${timeout}" >/dev/null 2>&1 < /dev/null &
  local wpid=$!
  disown "${wpid}" 2>/dev/null || true
  printf '%s\n' "${wpid}" > "${WATCH_PIDFILE}"
  _ok "watcher PID ${wpid} — no manual 'enable' needed after the flash"
}

case "${1:-}" in
  disable) disable ;;
  enable)  enable ;;
  status)  status ;;
  auto)    auto "${2:-}" ;;
  _watch)  _watch "${2:-}" ;;   # internal: backgrounded by auto
  *) printf 'Usage: %s {disable|enable|status|auto [timeout]}\n' "$0" >&2; exit 2 ;;
esac
