#!/usr/bin/env bash
# nm_flash_guard.sh — stop NetworkManager from breaking the initrd flash.
#
# The l4t_initrd_flash payload reaches the Jetson over a USB RNDIS/CDC
# gadget (host iface enxXXXX). The Jetson's *flash initrd* runs no DHCP
# server, so NetworkManager DHCPs the new iface, times out, and then
# REMOVES the address it briefly assigned — which tears down the link
# mid-transfer. The flash then stalls at a random point and dies with the
# misleading "Either the device cannot mount the NFS server" / Return 114.
# See issue #48.
#
# Fix: while flashing, tell NetworkManager to leave USB gadget ethernet
# interfaces alone. AFTER flashing, hand them back — the *booted* L4T
# usb0 DOES run a DHCP server (192.168.55.1) and you WANT NM to manage it
# so the host gets 192.168.55.100 and can reach the board. So this is a
# flash-scoped toggle, not a permanent rule.
#
# Usage:
#   ./script/nm_flash_guard.sh disable        # before `make run -- -t flash`
#   ./script/nm_flash_guard.sh enable         # after flashing, to reach the board
#   ./script/nm_flash_guard.sh around make run -- -t flash
#                                             # disable, run the cmd, enable on exit
#   ./script/nm_flash_guard.sh auto [timeout] # disable, then re-enable the
#                                             # moment the board boots (0955:7020),
#                                             # or after <timeout>s (default 1800)
#   ./script/nm_flash_guard.sh status

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"

CONF="${NM_GUARD_CONF:-/etc/NetworkManager/conf.d/99-jetson-flash-unmanaged.conf}"
# Host-side drivers that bind a Jetson USB gadget ethernet function.
DRIVERS='driver:rndis_host;driver:cdc_ether;driver:cdc_ncm;driver:cdc_subset'
# Auto-mode watcher bookkeeping.
WATCH_PIDFILE="${NM_GUARD_PIDFILE:-${TMPDIR:-/tmp}/nm-jetson-flash-guard.pid}"
POLL_INTERVAL="${NM_GUARD_POLL_INTERVAL:-3}"
AUTO_TIMEOUT_DEFAULT="${NM_GUARD_TIMEOUT:-1800}"

_step() { printf '\n\033[36m[nm-guard] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }

_nm_active() { command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; }
_reload()    { sudo nmcli general reload 2>/dev/null || sudo systemctl reload NetworkManager; }

disable() {
  _step "Disabling NetworkManager control of USB gadget interfaces (flash mode)"
  if ! _nm_active; then
    printf '  NetworkManager not active — nothing to do (no IP-loss risk)\n' >&2
    return 0
  fi
  printf '[keyfile]\nunmanaged-devices=%s\n' "${DRIVERS}" | sudo tee "${CONF}" >/dev/null
  _reload
  _ok "USB RNDIS/CDC interfaces are now unmanaged — safe to flash"
}

enable() {
  _step "Re-enabling NetworkManager control of USB gadget interfaces (normal mode)"
  if [[ -e "${CONF}" ]]; then
    sudo rm -f "${CONF}"
    # Don't mask a real reload failure with `|| true`: if NM is active but the
    # reload fails, the guard file is gone yet NM never re-reads config, so the
    # host never DHCPs the booted board — surface it instead of printing "ok".
    if _nm_active; then
      _reload || printf '  warning: NetworkManager reload failed — run: sudo nmcli general reload\n' >&2
    fi
    _ok "Removed ${CONF##*/} — NM will DHCP the booted Jetson usb0 (192.168.55.100)"
  else
    printf '  No guard file present — already in normal mode\n' >&2
  fi
}

status() {
  _step "NetworkManager flash-guard status"
  if [[ -e "${CONF}" ]]; then
    printf '  DISABLED (flash mode): %s present\n' "${CONF}" >&2
  else
    printf '  ENABLED (normal mode): no guard file\n' >&2
  fi
  if [[ -e "${WATCH_PIDFILE}" ]] && kill -0 "$(cat "${WATCH_PIDFILE}" 2>/dev/null)" 2>/dev/null; then
    printf '  AUTO watcher running (PID %s) — will re-enable on boot (0955:%s)\n' \
      "$(cat "${WATCH_PIDFILE}")" "${JETSON_BOOTED_PID}" >&2
  fi
  _nm_active && nmcli device status 2>/dev/null | grep -iE 'enx|usb|DEVICE' >&2 || true
}

# _watch <timeout> — poll the USB bus; re-enable NM the moment the board
# boots (JETSON_BOOTED_PID), or unconditionally after <timeout> seconds so
# an aborted flash never leaves NetworkManager parked off. Runs detached
# (backgrounded by auto); also callable directly for tests.
_watch() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}" waited=0
  while (( waited < timeout )); do
    if jetson_is_booted_l4t; then
      _step "Jetson booted (0955:${JETSON_BOOTED_PID}) — handing usb0 back to NetworkManager"
      enable
      rm -f "${WATCH_PIDFILE}" 2>/dev/null || true
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done
  _step "Auto watcher timed out after ${timeout}s — restoring NetworkManager so it isn't left disabled"
  enable
  rm -f "${WATCH_PIDFILE}" 2>/dev/null || true
}

# auto [timeout] — one-shot for both flash paths: drop NM control now, then
# background a watcher that restores it as soon as the board boots. Replaces
# the manual disable-then-enable dance, which the SDK Manager GUI flow makes
# especially awkward (flash-write needs NM off, post-flash install needs it on).
auto() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}"
  disable
  _step "Starting auto watcher (re-enable on boot 0955:${JETSON_BOOTED_PID}, or after ${timeout}s)"
  setsid bash "${BASH_SOURCE[0]}" _watch "${timeout}" >/dev/null 2>&1 < /dev/null &
  local wpid=$!
  disown "${wpid}" 2>/dev/null || true
  printf '%s\n' "${wpid}" > "${WATCH_PIDFILE}"
  _ok "watcher PID ${wpid} — no manual 'enable' needed after the flash"
}

around() {
  shift_cmd=("$@")
  [[ ${#shift_cmd[@]} -gt 0 ]] || { printf 'around: no command given\n' >&2; exit 2; }
  disable
  # restore on ANY exit (success, failure, Ctrl-C)
  trap 'enable' EXIT INT TERM
  _step "Running: ${shift_cmd[*]}"
  "${shift_cmd[@]}"
}

case "${1:-}" in
  disable) disable ;;
  enable)  enable ;;
  status)  status ;;
  auto)    auto "${2:-}" ;;
  around)  around "${@:2}" ;;
  _watch)  _watch "${2:-}" ;;   # internal: backgrounded by auto
  *) printf 'Usage: %s {disable|enable|status|auto [timeout]|around <cmd...>}\n' "$0" >&2; exit 2 ;;
esac
