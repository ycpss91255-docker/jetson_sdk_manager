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
# Trust model. `enable` writes, as root, to the port path `disable`
# recorded — so that record must not be forgeable and is re-checked before
# every write: the state lives in a root-owned directory under /run (no
# local user can pre-create it), the path must be a root-hub usb_port under
# USB_SYSFS with no symlink in its tail (lib/usb.sh usb_ss_port_ok), the
# pidfile's PID is only ever killed when /proc says it is one of our
# watchers, and the watcher carries a per-disable token so a superseded
# one never undoes a newer guard. The `auto` watcher itself is started as
# root (`sudo -n … _spawn`) while the credential from `disable` is fresh,
# so it needs no tty later (the nm_flash_guard #77 problem does not apply).
#
# Paths are overridable so the bats suite can drive every branch against a
# fixture tree without root or hardware: USB_SYSFS, USB_SS_GUARD_STATE_DIR
# (both defined in lib/usb.sh), USB_SS_GUARD_POLL_INTERVAL,
# USB_SS_GUARD_TIMEOUT.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"

STATE_DIR="${USB_SS_GUARD_STATE_DIR}"
STATE_FILE="${STATE_DIR}/state"          # port=<usb_port dir>\ntoken=<hex>
WATCH_PIDFILE="${STATE_DIR}/watch.pid"   # written by the watcher itself
WATCH_FAILED="${STATE_DIR}/watch.failed" # the watcher could not re-enable
POLL_INTERVAL="${USB_SS_GUARD_POLL_INTERVAL:-3}"
AUTO_TIMEOUT_DEFAULT="${USB_SS_GUARD_TIMEOUT:-1800}"

_step() { printf '\n\033[36m[usb-ss-guard] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }
_warn() { printf '  %s\n' "$1" >&2; }
_err()  { printf '  error: %s\n' "$1" >&2; }

# Privileged writes always go through sudo, also from the root watcher:
# root needs no password and no tty for it, and one code path keeps the
# test double (a stubbed sudo) honest for every branch.
_sudo() { sudo "$@"; }

# _attr <dir> <name> — first line of a sysfs attribute, empty when unreadable.
_attr() { head -n1 "$1/$2" 2>/dev/null || true; }

# ── state ────────────────────────────────────────────────────────────

# _state_dir_ok — the directory must exist, not be a symlink, belong to
# root or to us, and not be writable by anyone else. Nobody else can then
# have planted a state file or a pidfile in it.
_state_dir_ok() {
  local uid mode
  [[ -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] || return 1
  uid="$(stat -c %u "${STATE_DIR}" 2>/dev/null)" || return 1
  [[ "${uid}" == 0 || "${uid}" == "$(id -u)" ]] || return 1
  mode="$(stat -c %a "${STATE_DIR}" 2>/dev/null)" || return 1
  (( (8#${mode} & 8#022) == 0 ))
}

_state_dir_ensure() {
  if [[ ! -d "${STATE_DIR}" ]]; then
    _sudo mkdir -p -m 0755 "${STATE_DIR}" 2>/dev/null || true
  fi
  _state_dir_ok || { _err "could not create or verify ${STATE_DIR} (it must exist, be root-owned and not a symlink) — refusing to disable a port without a safe place to record it"; return 1; }
}

# _state_file_ok — a regular file (no symlink) with exactly the two lines
# we write; ownership is implied by the directory check.
_state_file_ok() {
  [[ -f "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || return 1
  local n
  n="$(grep -cE '^(port=/.+|token=[0-9a-f]+)$' "${STATE_FILE}" 2>/dev/null || true)"
  [[ "${n}" == 2 ]] && [[ "$(wc -l <"${STATE_FILE}")" == 2 ]]
}
_state_port()  { usb_ss_state_port "${STATE_FILE}"; }
_state_token() { sed -n 's/^token=//p' "${STATE_FILE}" 2>/dev/null | head -n1; }
_new_token()   { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
_state_write() { printf 'port=%s\ntoken=%s\n' "$1" "$2" | _sudo tee "${STATE_FILE}" >/dev/null; }
_state_clear() { _sudo rm -f "${STATE_FILE}"; }

# _state_check — classify the recorded state for callers:
#   prints "none" | "disabled <port>" | "stale <port>" | "invalid <port>"
# and returns 0 for the first three, 1 for invalid (never write to it).
_state_check() {
  local port
  [[ -e "${STATE_FILE}" ]] || { printf 'none\n'; return 0; }
  if ! _state_dir_ok || ! _state_file_ok; then
    printf 'invalid %s\n' "$(_state_port)"; return 1
  fi
  port="$(_state_port)"
  if ! usb_ss_port_ok "${port}"; then
    printf 'invalid %s\n' "${port}"; return 1
  fi
  if [[ "$(_attr "${port}" disable)" == "1" ]]; then
    printf 'disabled %s\n' "${port}"
  else
    printf 'stale %s\n' "${port}"
  fi
}

_invalid_state_msg() {
  _err "state file ${STATE_FILE} does not name a valid root-hub port under ${USB_SYSFS} (${1:-?}) — not a valid guard state; inspect it and remove it with: sudo rm -f ${STATE_FILE}"
}

# ── sysfs lookups ────────────────────────────────────────────────────

# _jetson_dev — the sysfs directory name (e.g. 3-1) of the Jetson to
# anchor on: a board in recovery, or — for a flash already in progress —
# the initrd flash device. Prints nothing when neither is there.
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

# _port_of <dev> — the root-hub usb_port a device N-M hangs off:
# usbN/N-0:1.0/usbN-portM. Returns 1 for N-M.X (behind a hub): hub ports
# carry no ACPI location, so there is no sibling to resolve there.
_port_of() {
  local bus="${1%%-*}" path="${1#*-}"
  [[ "${path}" != *.* ]] || return 1
  printf '%s/usb%s/%s-0:1.0/usb%s-port%s\n' "${USB_SYSFS}" "${bus}" "${bus}" "${bus}" "${path}"
}

# _peers_of <port dir> — every root-hub usb_port on ANOTHER root hub whose
# speed is SuperSpeed (≥ 5000) and whose non-zero ACPI location equals the
# anchor's: the SS half of the same physical connector. One line each; the
# caller insists on exactly one.
_peers_of() {
  local port="$1" loc bus cand cbus
  loc="$(_attr "${port}" location)"
  [[ -n "${loc}" ]] || return 0
  [[ "${loc}" =~ ^0x0*$ ]] && return 0
  bus="${port##*/usb}"; bus="${bus%%-*}"
  for cand in "${USB_SYSFS}"/usb*/*-0:1.0/usb*-port*/; do
    cand="${cand%/}"
    [[ "${cand}" == "${port}" ]] && continue
    cbus="${cand##*/usb}"; cbus="${cbus%%-*}"
    [[ "${cbus}" != "${bus}" ]] || continue
    [[ "$(_attr "${cand}" location)" == "${loc}" ]] || continue
    [[ "$(_attr "${USB_SYSFS}/usb${cbus}" speed)" =~ ^[0-9]+$ ]] || continue
    (( $(_attr "${USB_SYSFS}/usb${cbus}" speed) >= 5000 )) || continue
    printf '%s\n' "${cand}"
  done
  return 0
}

# _write_disable <port dir> <0|1> — via sudo tee (sysfs is root-only), then
# read back: a write that did not take is a failure, not a silent "ok".
_write_disable() {
  printf '%s\n' "$2" | _sudo tee "$1/disable" >/dev/null 2>&1 || true
  [[ "$(_attr "$1" disable)" == "$2" ]]
}

# ── watcher bookkeeping ──────────────────────────────────────────────

# _is_watcher_pid <pid> — true when /proc says this PID is one of ours.
_is_watcher_pid() {
  local c
  [[ "$1" =~ ^[0-9]+$ ]] && [[ -d "/proc/$1" ]] || return 1
  c="$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)" || return 1
  [[ "${c}" == *usb_ss_guard.sh* && "${c}" == *" _watch "* ]]
}

# _stop_watcher — kill the watcher the pidfile names, but only after /proc
# confirms it is a usb_ss_guard watcher; anything else is left alone and
# just the pidfile goes. Never kills the caller (the watcher calls enable).
_stop_watcher() {
  local pid
  [[ -e "${WATCH_PIDFILE}" ]] || return 0
  pid="$(head -n1 "${WATCH_PIDFILE}" 2>/dev/null || true)"
  if [[ "${pid}" == "$$" ]]; then
    return 0
  elif _is_watcher_pid "${pid}"; then
    _sudo kill "${pid}" 2>/dev/null || true
    _ok "stopped watcher (PID ${pid})"
  elif [[ "${pid}" =~ ^[0-9]+$ && -d "/proc/${pid}" ]]; then
    _warn "pidfile names PID ${pid}, which is not a usb_ss_guard watcher — not killing it, dropping the pidfile"
  fi
  _sudo rm -f "${WATCH_PIDFILE}"
}

# ── commands ─────────────────────────────────────────────────────────

disable() {
  _step "Disabling the SuperSpeed half of the Jetson's USB connector (flash mode)"
  local dev port peers peer loc n kind rec
  if [[ -e "${STATE_FILE}" ]]; then
    rec="$(_state_check)" || { _invalid_state_msg "${rec#invalid }"; return 1; }
    kind="${rec%% *}"; peer="${rec#* }"
    case "${kind}" in
      disabled)
        # Fresh token: a watcher started for the previous disable must not
        # undo this one.
        _state_write "${peer}" "$(_new_token)"
        _ok "${peer##*/} already disabled (recorded in ${STATE_FILE})"
        return 0 ;;
      stale)
        _warn "stale state: ${peer##*/} is recorded but reads disable=0 — clearing it"
        _state_clear ;;
    esac
  fi
  dev="$(_jetson_dev)"
  if [[ -z "${dev}" ]]; then
    _warn "no Jetson in recovery (0955:${JETSON_RECOVERY_PIDS[0]}…) or initrd flash (0955:${JETSON_INITRD_PID}) on the USB bus — nothing to guard"
    return 0
  fi
  if ! port="$(_port_of "${dev}")"; then
    _warn "Jetson ${dev} is behind a hub — hub ports carry no ACPI location, so the SuperSpeed sibling cannot be resolved; nothing disabled (use a direct host port)"
    return 0
  fi
  if [[ ! -d "${port}" ]]; then
    _warn "Jetson is ${dev} but its port ${port##*/} is not in ${USB_SYSFS} — nothing to guard"
    return 0
  fi
  if [[ "$(_attr "${USB_SYSFS}/${dev}" speed)" =~ ^[0-9]+$ ]] && (( $(_attr "${USB_SYSFS}/${dev}" speed) >= 5000 )); then
    _warn "Jetson ${dev} is already enumerated at SuperSpeed on ${port##*/} — nothing to guard (the high-speed half is never disabled)"
    return 0
  fi
  loc="$(_attr "${port}" location)"
  peers="$(_peers_of "${port}")"
  n="$(printf '%s\n' "${peers}" | grep -c . || true)"
  if (( n == 0 )); then
    _warn "Jetson ${dev} is on ${port##*/} (location ${loc:-?}) and it has no SuperSpeed sibling — USB-2-only cable? nothing to disable"
    return 0
  elif (( n > 1 )); then
    _warn "location ${loc} is shared by more than one SuperSpeed port ($(printf '%s\n' "${peers}" | sed 's|.*/||' | paste -sd' ')) — ambiguous, refusing to disable any"
    return 0
  fi
  peer="${peers}"
  if [[ ! -e "${peer}/disable" ]]; then
    _warn "${peer##*/} is the SuperSpeed half of ${port##*/} (location ${loc}) but this kernel exposes no 'disable' attribute for it — cannot guard; if the flash loops on 'Cannot enable', try a different port or host"
    return 0
  fi
  if ! usb_ss_port_ok "${peer}"; then
    _err "${peer} is not a plain root-hub port directory (symlink?) — refusing to write to it"
    return 1
  fi
  _state_dir_ensure || return 1
  if ! _write_disable "${peer}" 1; then
    _err "could not write 1 to ${peer}/disable (sudo?) — run: echo 1 | sudo tee ${peer}/disable"
    return 1
  fi
  _state_write "${peer}" "$(_new_token)"
  _ok "Jetson ${dev} is on ${port##*/}; disabled its SuperSpeed sibling ${peer##*/} (location ${loc}) — the high-speed link stays up"
}

# _enable_port [token] — restore the recorded port. With a token, only when
# the state still carries it (a newer disable/auto owns the port otherwise).
_enable_port() {
  local want="${1:-}" rec kind port
  if [[ ! -e "${STATE_FILE}" ]]; then
    _warn "no state file (${STATE_FILE}) — nothing to re-enable"
    return 0
  fi
  rec="$(_state_check)" || { _invalid_state_msg "${rec#invalid }"; return 1; }
  kind="${rec%% *}"; port="${rec#* }"
  if [[ -n "${want}" && "$(_state_token)" != "${want}" ]]; then
    _warn "state was superseded by a newer disable — leaving ${port##*/} to its owner"
    return 0
  fi
  if [[ "${kind}" == stale ]]; then
    _warn "stale state: ${port##*/} already reads disable=0 — clearing the state file"
    _state_clear
    return 0
  fi
  if ! _write_disable "${port}" 0; then
    _err "could not re-enable ${port##*/} (sudo needs a tty?) — run: echo 0 | sudo tee ${port}/disable"
    return 1
  fi
  _state_clear
  _sudo rm -f "${WATCH_FAILED}"
  _ok "${port##*/} enabled again — the connector is back to USB 3"
}

enable() {
  _step "Re-enabling the SuperSpeed half of the Jetson's USB connector (normal mode)"
  _stop_watcher
  _enable_port
}

status() {
  _step "USB SuperSpeed flash-guard status"
  local rec kind port pid
  rec="$(_state_check)" || true
  kind="${rec%% *}"; port="${rec#* }"
  case "${kind}" in
    none)     printf '  ENABLED (normal mode): no port disabled by this guard\n' >&2 ;;
    disabled) printf '  DISABLED (flash mode): %s (disable=1), recorded in %s\n' "${port##*/}" "${STATE_FILE}" >&2 ;;
    stale)    printf '  STALE (stale state): %s is recorded in %s but reads disable=0 — run: %s enable\n' "${port##*/}" "${STATE_FILE}" "${BASH_SOURCE[0]}" >&2 ;;
    *)        printf '  INVALID: %s names %s, not a valid root-hub port — inspect it; sudo rm -f %s\n' "${STATE_FILE}" "${port:-?}" "${STATE_FILE}" >&2 ;;
  esac
  if [[ -e "${WATCH_FAILED}" ]]; then
    printf '  AUTO watcher could not re-enable the port — %s' "$(cat "${WATCH_FAILED}" 2>/dev/null)" >&2
  fi
  if [[ -e "${WATCH_PIDFILE}" ]]; then
    pid="$(head -n1 "${WATCH_PIDFILE}" 2>/dev/null || true)"
    if _is_watcher_pid "${pid}"; then
      printf '  AUTO watcher running (PID %s) — will re-enable on boot (0955:%s)\n' "${pid}" "${JETSON_BOOTED_PID}" >&2
    else
      printf '  AUTO watcher pidfile present but no watcher with that PID — if the port is still off, run: %s enable\n' "${BASH_SOURCE[0]}" >&2
    fi
  fi
}

# ── auto watcher ─────────────────────────────────────────────────────

# _reenable_or_mark <token> — restore the port and clear the pidfile; on
# failure leave a marker so `status` can report it (the detached watcher's
# output goes nowhere). Direct writes: the watcher runs as root for real
# and as the test user against a tmpdir in bats.
_reenable_or_mark() {
  if _enable_port "$1"; then
    rm -f "${WATCH_FAILED}" 2>/dev/null || true
  else
    printf 'could not re-enable the SuperSpeed port. Run: %s enable\n' "${BASH_SOURCE[0]}" \
      >"${WATCH_FAILED}" 2>/dev/null || true
  fi
}

# _pidfile_release — drop the pidfile only if it is ours.
_pidfile_release() {
  [[ "$(head -n1 "${WATCH_PIDFILE}" 2>/dev/null || true)" == "$$" ]] && rm -f "${WATCH_PIDFILE}" 2>/dev/null
  return 0
}

# _watch <timeout> [token] — claim the pidfile (noclobber: if another
# watcher already owns it, leave), then poll the USB bus; re-enable the
# port the moment the board boots (JETSON_BOOTED_PID), or unconditionally
# after <timeout> seconds so an aborted flash never leaves the connector at
# USB 2. Backgrounded as root by auto; also callable directly (tests).
_watch() {
  local timeout="${1:-${AUTO_TIMEOUT_DEFAULT}}" token="${2:-}" waited=0
  if ! ( set -o noclobber; printf '%s\n' "$$" >"${WATCH_PIDFILE}" ) 2>/dev/null; then
    _warn "another watcher owns ${WATCH_PIDFILE} — exiting"
    return 0
  fi
  trap '_pidfile_release' EXIT
  if [[ -n "${token}" && "$(_state_token)" != "${token}" ]]; then
    _warn "state was superseded by a newer disable — this watcher exits"
    return 0
  fi
  while (( waited < timeout )); do
    if jetson_is_booted_l4t; then
      _step "Jetson booted (0955:${JETSON_BOOTED_PID}) — re-enabling the SuperSpeed port"
      _reenable_or_mark "${token}"
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done
  _step "Auto watcher timed out after ${timeout}s — re-enabling the SuperSpeed port so it isn't left off"
  _reenable_or_mark "${token}"
}

# _spawn <timeout> <token> — run as root by auto (via sudo -n): detach the
# watcher into its own session and return at once, so sudo's exit status
# says whether the watcher could be started at all.
_spawn() {
  setsid bash "${BASH_SOURCE[0]}" _watch "$1" "$2" >/dev/null 2>&1 </dev/null &
  disown $! 2>/dev/null || true
}

# auto [timeout] — disable now, then start a root watcher that restores
# the port as soon as the board boots. Nothing disabled → no watcher.
auto() {
  local timeout="${AUTO_TIMEOUT_DEFAULT}" token rec
  if (( $# > 1 )); then
    printf 'Usage: %s auto [timeout]\n' "$0" >&2; return 2
  elif (( $# == 1 )); then
    if [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then
      printf 'usb_ss_guard: auto expects a timeout in whole seconds (> 0), got: "%s"\n' "$1" >&2; return 2
    fi
    timeout="$1"
  fi
  # One watcher at a time: a previous `auto` still polling would race this
  # one for the port (and its token no longer matches after disable anyway).
  _stop_watcher
  disable || return 1
  rec="$(_state_check)" || return 1
  if [[ "${rec%% *}" != disabled ]]; then
    _ok "nothing disabled — no watcher needed"
    return 0
  fi
  token="$(_state_token)"
  _sudo rm -f "${WATCH_FAILED}"
  _step "Starting auto watcher as root (re-enable on boot 0955:${JETSON_BOOTED_PID}, or after ${timeout}s)"
  # Root, detached, no tty: started while the credential from disable() is
  # still fresh, so the eventual re-enable never needs sudo again. `-n`
  # rather than a prompt: a refusal must be reported, not hang.
  if ! sudo -n bash "${BASH_SOURCE[0]}" _spawn "${timeout}" "${token}" </dev/null; then
    _warn "could not start the watcher (sudo -n refused — credential expired or tty_tickets without a cached one)."
    _warn "The SuperSpeed port stays parked: after the flash run '${BASH_SOURCE[0]} enable' (host_teardown.sh does), or reboot."
    return 0
  fi
  # The watcher writes its own pidfile before it does anything else; wait
  # for that (or for it to have already finished, which clears the state).
  for _ in $(seq 1 40); do
    [[ -s "${WATCH_PIDFILE}" || ! -e "${STATE_FILE}" ]] && break
    sleep 0.25
  done
  if [[ -s "${WATCH_PIDFILE}" ]]; then
    _ok "watcher PID $(head -n1 "${WATCH_PIDFILE}") — no manual 'enable' needed after the flash"
  elif [[ ! -e "${STATE_FILE}" ]]; then
    _ok "board already booted — the watcher has restored the port"
  else
    _warn "watcher did not report in — if the port stays off after the flash run: ${BASH_SOURCE[0]} enable"
  fi
}

case "${1:-}" in
  disable) disable ;;
  enable)  enable ;;
  status)  status ;;
  auto)    auto "${@:2}" ;;
  _spawn)  _spawn "${2:-}" "${3:-}" ;;   # internal: run as root by auto
  _watch)  _watch "${2:-}" "${3:-}" ;;   # internal: backgrounded by _spawn
  *) printf 'Usage: %s {disable|enable|status|auto [timeout]}\n' "$0" >&2; exit 2 ;;
esac
