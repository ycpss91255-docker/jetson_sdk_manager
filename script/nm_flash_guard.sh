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
#   ./script/nm_flash_guard.sh watch [timeout]# like auto but FOREGROUND — keeps
#                                             # the tty so the post-boot re-enable's
#                                             # sudo works on tty_tickets hosts (#80)
#   ./script/nm_flash_guard.sh install-autohook   # one-time: NOPASSWD hook so the
#                                             # detached `auto` re-enables NM with no
#                                             # tty. uninstall-autohook reverses it.
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
# Opt-in NOPASSWD autohook (install-autohook): a narrow root helper plus a
# sudoers drop-in scoped to ONLY that helper, so the detached `auto` watcher
# can re-enable NM without a tty on tty_tickets sudo hosts (#80).
AUTOHOOK_BIN="${NM_GUARD_AUTOHOOK:-/usr/local/sbin/jetson-nm-flash-guard-reenable}"
SUDOERS_FILE="${NM_GUARD_SUDOERS:-/etc/sudoers.d/jetson-nm-flash-guard}"
AUTOHOOK_USER="${NM_GUARD_USER:-$(id -un)}"

_step() { printf '\n\033[36m[nm-guard] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }

_nm_active() { command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; }
_reload()    { sudo nmcli general reload 2>/dev/null || sudo systemctl reload NetworkManager; }
# True only when sudo will run WITHOUT prompting. The auto-mode watcher is
# detached (no controlling tty), so on tty_tickets hosts it cannot reuse the
# interactive credential cached by disable() — see #77.
_sudo_noninteractive_ok() { sudo -n true 2>/dev/null; }

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

# _reenable_via_autohook — if the opt-in NOPASSWD autohook is installed, use it
# to drop the guard + reload NM without a tty (works from the detached watcher
# on tty_tickets hosts). Returns 0 only when the guard file is actually gone.
_reenable_via_autohook() {
  [[ -x "${AUTOHOOK_BIN}" ]] || return 1
  sudo -n "${AUTOHOOK_BIN}" 2>/dev/null || return 1
  [[ ! -e "${CONF}" ]]
}

enable() {
  _step "Re-enabling NetworkManager control of USB gadget interfaces (normal mode)"
  if [[ -e "${CONF}" ]]; then
    # Prefer the opt-in NOPASSWD autohook (#80) — the one path that works from a
    # detached, tty-less watcher. Falls through to interactive sudo otherwise.
    if _reenable_via_autohook; then
      _ok "Removed ${CONF##*/} via autohook — NM will DHCP the booted Jetson usb0 (192.168.55.100)"
      return 0
    fi
    sudo rm -f "${CONF}" 2>/dev/null || true
    # The detached auto watcher may not be able to sudo (no tty, #77). If the
    # guard file is still here, the removal failed — report it and return
    # non-zero so callers (the watcher) can mark the failure instead of
    # mistaking a still-disabled NM for success.
    if [[ -e "${CONF}" ]]; then
      printf '  error: could not remove %s (sudo needs a tty?) — run: sudo rm -f %s && sudo nmcli general reload\n' \
        "${CONF}" "${CONF}" >&2
      return 1
    fi
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
  if [[ -e "${WATCH_PIDFILE}.failed" ]]; then
    printf '  AUTO watcher could not re-enable NM — %s' \
      "$(cat "${WATCH_PIDFILE}.failed" 2>/dev/null)" >&2
  elif [[ -e "${WATCH_PIDFILE}" ]] && kill -0 "$(cat "${WATCH_PIDFILE}" 2>/dev/null)" 2>/dev/null; then
    printf '  AUTO watcher running (PID %s) — will re-enable on boot (0955:%s)\n' \
      "$(cat "${WATCH_PIDFILE}")" "${JETSON_BOOTED_PID}" >&2
  elif [[ -e "${WATCH_PIDFILE}" ]]; then
    printf '  AUTO watcher pidfile present but the process is dead — if the guard is still on, run: %s enable\n' \
      "${BASH_SOURCE[0]}" >&2
  fi
  if [[ -x "${AUTOHOOK_BIN}" ]]; then
    printf '  autohook: installed (%s) — detached auto re-enables NM without a tty\n' "${AUTOHOOK_BIN}" >&2
  else
    printf '  autohook: not installed (auto re-enable needs passwordless sudo, the foreground "watch" mode, or "install-autohook")\n' >&2
  fi
  _nm_active && nmcli device status 2>/dev/null | grep -iE 'enx|usb|DEVICE' >&2 || true
}

# _watch <timeout> — poll the USB bus; re-enable NM the moment the board
# boots (JETSON_BOOTED_PID), or unconditionally after <timeout> seconds so
# an aborted flash never leaves NetworkManager parked off. Runs detached
# (backgrounded by auto); also callable directly for tests.
# _reenable_or_mark — re-enable NM and clear watcher state. If the re-enable
# fails (e.g. the detached watcher can't sudo without a tty, #77), leave a
# `.failed` marker so `status` reports it and the still-active guard isn't
# mistaken for a clean exit. Output is discarded for the detached watcher, so
# the marker file is the only channel the user can see.
_reenable_or_mark() {
  if enable; then
    rm -f "${WATCH_PIDFILE}" "${WATCH_PIDFILE}.failed" 2>/dev/null || true
  else
    printf 'could not re-enable NetworkManager (sudo needs a tty?). Run: %s enable\n' \
      "${BASH_SOURCE[0]}" > "${WATCH_PIDFILE}.failed" 2>/dev/null || true
    rm -f "${WATCH_PIDFILE}" 2>/dev/null || true
  fi
}

_watch() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}" waited=0
  while (( waited < timeout )); do
    if jetson_is_booted_l4t; then
      _step "Jetson booted (0955:${JETSON_BOOTED_PID}) — handing usb0 back to NetworkManager"
      _reenable_or_mark
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done
  _step "Auto watcher timed out after ${timeout}s — restoring NetworkManager so it isn't left disabled"
  _reenable_or_mark
}

# auto [timeout] — one-shot for both flash paths: drop NM control now, then
# background a watcher that restores it as soon as the board boots. Replaces
# the manual disable-then-enable dance, which the SDK Manager GUI flow makes
# especially awkward (flash-write needs NM off, post-flash install needs it on).
auto() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}"
  disable
  # The watcher below is detached (no tty). On tty_tickets sudo hosts it cannot
  # reuse the credential the interactive disable() just cached, so its post-boot
  # re-enable will fail — UNLESS the opt-in autohook is installed (#80), which
  # gives it a NOPASSWD path. Warn only when neither will work, rather than
  # silently leaving NM off (#77).
  if [[ -x "${AUTOHOOK_BIN}" ]]; then
    _ok "autohook present — watcher will re-enable NM automatically after boot"
  elif ! _sudo_noninteractive_ok; then
    _step "Heads-up: sudo needs a password on this host (tty_tickets)"
    printf '  The background watcher has no tty and may NOT re-enable NetworkManager\n' >&2
    printf '  after the board boots. Options:\n' >&2
    printf '    - run a foreground watcher instead:  %s watch\n' "${BASH_SOURCE[0]}" >&2
    printf '    - or install the one-time autohook:  %s install-autohook\n' "${BASH_SOURCE[0]}" >&2
    printf '    - or, if you cannot reach the board:  %s enable\n' "${BASH_SOURCE[0]}" >&2
  fi
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

# install-autohook — opt-in: make the detached `auto` watcher able to re-enable
# NM with no tty (#80). Installs a narrow root helper that removes ONLY the
# known guard file + reloads NM, plus a sudoers drop-in scoped to ONLY that
# helper. The drop-in is validated with `visudo -c` and installed atomically —
# a malformed file is never put in place (that could lock the user out of sudo).
install_autohook() {
  _step "Installing NOPASSWD autohook for ${AUTOHOOK_USER} (so 'auto' re-enables NM without a tty)"
  local tmp_helper tmp_sudoers
  tmp_helper="$(mktemp)"
  tmp_sudoers="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_helper}' '${tmp_sudoers}'" RETURN

  cat > "${tmp_helper}" <<EOF
#!/usr/bin/env bash
# Installed by nm_flash_guard.sh install-autohook (#80). Invoked as root via a
# NOPASSWD sudoers entry scoped to ONLY this path, so the detached auto watcher
# can hand usb0 back to NetworkManager without a controlling tty. Does the bare
# minimum: remove the known flash guard file and reload NM.
set -euo pipefail
conf='${CONF}'
rm -f "\${conf}"
nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
EOF

  printf '%s ALL=(root) NOPASSWD: %s\n' "${AUTOHOOK_USER}" "${AUTOHOOK_BIN}" > "${tmp_sudoers}"
  if ! visudo -cf "${tmp_sudoers}" >/dev/null 2>&1; then
    printf '  error: generated sudoers entry failed validation — aborting (no changes made)\n' >&2
    return 1
  fi

  sudo install -m 0755 -o root -g root "${tmp_helper}" "${AUTOHOOK_BIN}"
  sudo install -m 0440 -o root -g root "${tmp_sudoers}" "${SUDOERS_FILE}"
  _ok "autohook: ${AUTOHOOK_BIN}"
  _ok "sudoers: ${SUDOERS_FILE} (NOPASSWD for that helper only)"
  _ok "'auto' will now re-enable NM automatically after boot — no manual 'enable'"
}

# uninstall-autohook — remove both pieces install-autohook added.
uninstall_autohook() {
  _step "Removing NOPASSWD autohook"
  sudo rm -f "${AUTOHOOK_BIN}" "${SUDOERS_FILE}"
  _ok "removed ${AUTOHOOK_BIN} and ${SUDOERS_FILE}"
}

# _sudo_keepalive_start / _stop — refresh the sudo timestamp from a background
# job that shares this foreground session's controlling tty, so a long flash
# does not let the credential expire before the post-boot re-enable. Only used
# by the foreground `watch` mode (the detached `auto` watcher has no tty).
_KEEPALIVE_PID=""
_sudo_keepalive_start() {
  ( while true; do sudo -n -v 2>/dev/null || exit 0; sleep 60; done ) &
  _KEEPALIVE_PID=$!
}
_sudo_keepalive_stop() {
  [[ -n "${_KEEPALIVE_PID}" ]] && kill "${_KEEPALIVE_PID}" 2>/dev/null || true
  _KEEPALIVE_PID=""
}

# watch — foreground alternative to `auto` (#80) for the long SDK Manager GUI
# flow: run this in a spare terminal. It keeps the controlling tty, so the
# post-boot re-enable's sudo works even on tty_tickets hosts with no autohook
# installed. Blocks until the board boots (or <timeout>s).
watch_fg() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}"
  disable
  _step "Foreground watcher — KEEP THIS TERMINAL OPEN. Re-enables NM on boot (0955:${JETSON_BOOTED_PID}) or after ${timeout}s"
  _sudo_keepalive_start
  trap '_sudo_keepalive_stop' EXIT INT TERM
  _watch "${timeout}"
}

case "${1:-}" in
  disable) disable ;;
  enable)  enable ;;
  status)  status ;;
  auto)    auto "${2:-}" ;;
  watch)   watch_fg "${2:-}" ;;   # foreground watcher (keeps tty; #80)
  install-autohook)   install_autohook ;;
  uninstall-autohook) uninstall_autohook ;;
  around)  around "${@:2}" ;;
  _watch)  _watch "${2:-}" ;;   # internal: backgrounded by auto
  *) printf 'Usage: %s {disable|enable|status|auto [timeout]|watch [timeout]|install-autohook|uninstall-autohook|around <cmd...>}\n' "$0" >&2; exit 2 ;;
esac
