#!/usr/bin/env bash
# jetson.sh — the one command to remember (#95).
#
# A THIN dispatcher over the scripts this repo already ships. It sequences
# them, adds preflight checks that improve the experience (is the board in
# recovery? did prepare finish?), and prints what to do next. It never
# re-implements a step: host_setup.sh, prepare.sh (in the container),
# nm_flash_guard.sh, flash.sh, host_teardown.sh and clean.sh stay the
# authorities, and their own gates still apply if someone bypasses this.
#
#   ./jetson status              host readiness + Jetson USB state
#   ./jetson prepare             host_setup → init_data_dirs → make run -t prepare
#   ./jetson wait-rec [seconds]  poll until a Jetson shows up in recovery
#   ./jetson flash               (board in REC) nm guard → make run -t flash
#   ./jetson all                 prepare → wait-rec → flash
#   ./jetson teardown            host_teardown.sh
#   ./jetson purge [--yes] [--keep-downloads]   clean.sh purge
#
# Invoked through the top-level `./jetson` symlink; the repo root is
# resolved from this file's real location, never from the caller's cwd.

set -euo pipefail

_HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
_REPO="$(cd "${_HERE}/.." && pwd)"
# Overridable so the bats suite can point data/ at a tmpdir.
L4T_REPO_ROOT="${L4T_REPO_ROOT:-${_REPO}}"

# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"
# shellcheck source=lib/store.sh
. "${_HERE}/lib/store.sh"
# shellcheck source=lib/status.sh
. "${_HERE}/lib/status.sh"

# Sibling scripts — overridable for tests.
HOST_SETUP_BIN="${HOST_SETUP_BIN:-${_HERE}/host_setup.sh}"
INIT_DATA_DIRS_BIN="${INIT_DATA_DIRS_BIN:-${_HERE}/init_data_dirs.sh}"
NM_GUARD_BIN="${NM_GUARD_BIN:-${_HERE}/nm_flash_guard.sh}"
HOST_TEARDOWN_BIN="${HOST_TEARDOWN_BIN:-${_HERE}/host_teardown.sh}"
CLEAN_BIN="${CLEAN_BIN:-${_HERE}/clean.sh}"

_say()  { printf '\n\033[36m[jetson] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  \033[32m✔\033[0m %s\n' "$1" >&2; }
_warn() { printf '  \033[33m⚠\033[0m %s\n' "$1" >&2; }
_bad()  { printf '  \033[31m✘\033[0m %s\n' "$1" >&2; }
_die()  { _bad "$1"; [[ -n "${2:-}" ]] && printf '    → %s\n' "$2" >&2; exit 1; }

_usage() {
  cat >&2 <<'USAGE'
Usage: ./jetson <command>

  status                 What is ready, what is not, and whether the Jetson is in recovery.
  prepare [--no-board]   Host setup + download BSP + build flash images (~30 min). Board must be in REC:
                         the last step reads its board spec over USB (--no-board if you export BOARDID/FAB/…).
  wait-rec [seconds]     Show how to enter recovery (REC) and wait until the board appears.
  flash                  Write the images to a Jetson that is in recovery (~10 min).
  all [seconds]          wait-rec (timeout: seconds, default 0 = forever) → prepare → flash, stopping at the first problem.
  teardown               Undo the host changes from prepare (same boot; a reboot does the same).
  purge [--yes] [--keep-downloads]
                         Remove everything prepare produced, incl. the data store. Then rm -rf is safe.

Typical first flash:   put the board in REC   →   ./jetson prepare   →   ./jetson flash
USAGE
}

# ── preflight helpers ────────────────────────────────────────────────

# _phase_done <phase> — via lib/status.sh (sed-based, no yq). Exactly one
# prepared tree must exist; 0 → not prepared, >1 → ambiguous.
_phase_done() {
  local markers n
  markers="$(status_markers)"
  n="$(printf '%s\n' "${markers}" | grep -c . || true)"
  (( n == 1 )) || return 1
  status_phase_done "${markers}" "$1"
}

# _recovery_line — the lsusb line of THE Jetson in recovery.
#   returns 0 and prints the line  — exactly one board
#   returns 1                      — none (wait-rec may keep polling)
#   returns 2 and prints the list  — more than one: the flash tool would pick
#                                    whichever enumerates first, which is not
#                                    a choice anyone made. Callers must stop.
# Runs inside $(...), so it must not `exit`; the caller acts on the code.
_recovery_line() {
  local lines n
  lines="$(status_recovery_lines)"
  n="$(printf '%s\n' "${lines}" | grep -c . || true)"
  case "${n}" in
    0) return 1 ;;
    1) printf '%s\n' "${lines}"; return 0 ;;
    *) printf '%s\n' "${lines}"; return 2 ;;
  esac
}

# _die_multiple_recovery <lines>
_die_multiple_recovery() {
  _bad "$(printf '%s\n' "$1" | grep -c .) Jetsons in recovery on the USB bus — disconnect all but the one to flash"
  printf '%s\n' "$1" | sed 's/^/      /' >&2
  exit 1
}

_rec_instructions() {
  cat >&2 <<'REC'
  Put the Jetson into recovery (REC / APX) mode:
    1. Disconnect the power supply.
    2. USB-C cable: Jetson FRONT panel (the port next to the buttons) ↔ this host.
    3. Hold the REC button, reconnect power, release REC after ~2 s.
  The host then sees it as USB 0955:7023 (AGX Orin) or another PID in the APX recovery range.
REC
}

# ── commands ─────────────────────────────────────────────────────────

cmd_flash() {
  _say "flash — preflight"
  local rec rc=0
  rec="$(_recovery_line)" || rc=$?
  case "${rc}" in
    2) _die_multiple_recovery "${rec}" ;;
    1) _rec_instructions
       _die "no Jetson in recovery on the USB bus" "run ./jetson wait-rec, then ./jetson flash again" ;;
  esac
  _ok "Jetson in recovery: ${rec}"
  local nmarkers
  nmarkers="$(status_markers | grep -c . || true)"
  if (( nmarkers > 1 )); then
    _die "more than one prepared L4T tree under data/jetson_l4t — which one to flash is ambiguous" \
         "./script/clean.sh l4t, then ./jetson prepare"
  fi
  if ! _phase_done images; then
    _die "prepare has not produced flash images yet (no 'images' phase in .prepared.yaml)" \
         "run ./jetson prepare first"
  fi
  _ok "flash images present (prepare completed)"

  _say "flash — guarding NetworkManager for the USB link"
  "${NM_GUARD_BIN}" auto
  _say "flash — writing images (make run -- -t flash)"
  (cd "${_REPO}" && make run -- -t flash)
  _say "flash — done"
  cat >&2 <<'NEXT'
  The Jetson reboots into the new OS. Over the same USB-C cable it is reachable at:
    ssh <user>@192.168.55.1        (user / password from jetson.yaml — change the password!)
  Then finish JetPack on the device:
    sudo apt update && sudo apt install -y nvidia-jetpack
NEXT
}

# _sudo_once — one password prompt up front instead of one per sub-step.
# Non-interactive callers (CI, cron) get a fast failure rather than a hang.
_sudo_once() {
  if [[ -t 0 ]]; then
    sudo -v || _die "sudo is required for the host setup steps" "run this from a terminal where you can enter your password"
  else
    sudo -n -v 2>/dev/null || _die "sudo needs a password but there is no terminal to ask on" "run ./jetson prepare interactively once (sudo caches the credential)"
  fi
}

# cmd_prepare [--no-board]
# The last prepare step (l4t_initrd_flash --no-flash) runs NVIDIA's flash.sh,
# which reads the board spec (BOARDID / FAB / BOARDSKU / BOARDREV) from the
# EEPROM over the recovery USB link unless those are exported. So the board
# must already be in recovery — checked up front rather than at minute 30.
cmd_prepare() {
  local no_board="" arg
  for arg in "$@"; do
    case "${arg}" in
      --no-board) no_board=1 ;;
      *) printf 'jetson: prepare: unknown option %s\n\n' "${arg}" >&2; _usage; exit 2 ;;
    esac
  done
  _say "prepare — preflight"
  if [[ -z "${no_board}" ]]; then
    local rec rc=0
    rec="$(_recovery_line)" || rc=$?
    case "${rc}" in
      2) _die_multiple_recovery "${rec}" ;;
      1) _rec_instructions
         _die "no Jetson in recovery — prepare's last step reads the board spec from the board over USB" \
              "put the board in recovery (./jetson wait-rec), then ./jetson prepare. Exporting BOARDID FAB BOARDSKU BOARDREV yourself? add --no-board" ;;
    esac
    _ok "Jetson in recovery: ${rec}"
  else
    _warn "--no-board: skipping the recovery check; flash.sh needs BOARDID FAB BOARDSKU BOARDREV in the environment"
  fi
  _say "prepare — host setup (needs sudo once)"
  _sudo_once
  "${HOST_SETUP_BIN}" || _die "host_setup.sh failed — fix what it reported, then re-run ./jetson prepare"
  "${INIT_DATA_DIRS_BIN}" || _die "init_data_dirs.sh failed"
  _say "prepare — download BSP + build flash images (make run -- -t prepare, ~30 min first time)"
  (cd "${_REPO}" && make run -- -t prepare) || _die "prepare failed — see the log above" "fix the cause, then re-run ./jetson prepare (it resumes where it stopped)"
  _say "prepare — done. Next: ./jetson flash (the board is still in recovery)"
}

# cmd_wait_rec [seconds] — 0 = wait forever. Ctrl-C exits 130 and changes
# nothing (this command never touches NM or mounts).
cmd_wait_rec() {
  local timeout="${1:-300}" interval="${WAIT_REC_INTERVAL:-2}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || { printf 'jetson: wait-rec expects a number of seconds, got: %s\n' "${timeout}" >&2; exit 2; }
  [[ "${interval}" =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v i="${interval}" 'BEGIN{exit !(i>0)}' \
    || { printf 'jetson: WAIT_REC_INTERVAL must be a positive number of seconds, got: %s\n' "${interval}" >&2; exit 2; }
  _say "wait-rec — waiting for a Jetson in recovery (timeout: ${timeout}s, 0 = forever)"
  _rec_instructions
  # The poll runs in a subshell so the INT trap is scoped to it: after a
  # successful wait, ./jetson all continues into flash with no trap left
  # behind. Deadline is wall-clock (SECONDS), not a sum of sleeps.
  (
    trap 'printf "\n[jetson] wait-rec interrupted\n" >&2; exit 130' INT
    local rec rc start=${SECONDS} remaining nap
    while :; do
      rc=0; rec="$(_recovery_line)" || rc=$?
      case "${rc}" in
        0) _ok "Jetson in recovery: ${rec}"; exit 0 ;;
        2) _die_multiple_recovery "${rec}" ;;
      esac
      if (( timeout > 0 )); then
        remaining=$(( timeout - (SECONDS - start) ))
        if (( remaining <= 0 )); then
          _die "timed out after ${timeout}s — no Jetson in recovery" "check the cable is on the FRONT USB-C port, redo the REC sequence, then ./jetson wait-rec"
        fi
        nap="$(awk -v i="${interval}" -v r="${remaining}" 'BEGIN{print (i<r)?i:r}')"
      else
        nap="${interval}"
      fi
      sleep "${nap}"
    done
  )
}

cmd_all() {
  _say "[1/3] wait for recovery"
  cmd_wait_rec "${1:-0}"
  _say "[2/3] prepare"
  cmd_prepare
  _say "[3/3] flash"
  cmd_flash
}

cmd_teardown() {
  _say "teardown — restoring the host (host_teardown.sh)"
  "${HOST_TEARDOWN_BIN}"
}

cmd_purge() {
  local yes="" keep=() arg
  for arg in "$@"; do
    case "${arg}" in
      --yes|-y) yes=1 ;;
      --keep-downloads) keep+=("--keep-downloads") ;;
      *) printf 'jetson: purge: unknown option %s\n' "${arg}" >&2; exit 2 ;;
    esac
  done
  if [[ -z "${yes}" ]]; then
    printf '[jetson] purge removes the L4T tree, the data store image, the marker%s.\n' \
      "$([[ ${#keep[@]} -eq 0 ]] && printf ' and the cached tarballs')" >&2
    printf '         Type "yes" to continue: ' >&2
    local answer=""
    read -r answer || true
    [[ "${answer}" == "yes" ]] || { printf '[jetson] purge aborted\n' >&2; exit 1; }
  fi
  "${CLEAN_BIN}" purge "${keep[@]}"
}

# ── status ───────────────────────────────────────────────────────────

# Checks that live here rather than in lib/status.sh because they are
# about this host's tooling / images rather than the flash state.
_status_tools() {
  local t
  for t in docker make lsusb; do
    command -v "${t}" >/dev/null 2>&1 || { printf 'bad\t%s not installed\n' "${t}"; }
  done
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then printf 'ok\tdocker reachable without sudo\n'
    else printf 'bad\tdocker daemon not reachable as this user — add yourself to the docker group\n'; fi
  fi
}
_status_images() {
  local img missing=""
  for img in prepare probe flash; do
    docker image inspect "${DOCKER_HUB_USER:-${USER:-$(id -un)}}/jetson_sdk_manager:${img}" >/dev/null 2>&1 || missing="${missing} ${img}"
  done
  if [[ -z "${missing}" ]]; then printf 'ok\tdocker images built: prepare, probe, flash\n'
  else printf 'warn\tdocker images not built yet:%s (make run builds them on first use)\n' "${missing}"; fi
}
_status_nm() {
  if command -v systemctl >/dev/null 2>&1 && [[ "$(systemctl is-active NetworkManager 2>/dev/null)" == active ]]; then
    printf 'ok\tNetworkManager active — ./jetson flash guards it automatically (nm_flash_guard.sh auto)\n'
  else
    printf 'ok\tNetworkManager not active — no USB-link guard needed\n'
  fi
}
_status_srv() {
  local srv="${L4T_EXPORT_DIR:-/srv/jetson_l4t}" data="${L4T_REPO_ROOT}/data/jetson_l4t"
  if store_same_inode "${srv}" "${data}" 2>/dev/null; then printf 'ok\t%s bridged to data/jetson_l4t\n' "${srv}"
  else printf 'warn\t%s not bridged — only needed for flash; ./jetson prepare (host_setup.sh) does it\n' "${srv}"; fi
}

# The check list is overridable so the test suite can inject a failing one.
JETSON_STATUS_CHECKS="${JETSON_STATUS_CHECKS:-_status_tools status_config status_store _status_srv status_kernel _status_nm _status_images status_prepare status_jetson}"

cmd_status() {
  local strict="" bad=0 warn=0 level msg chk out
  [[ "${1:-}" == "--strict" ]] && strict=1
  _say "status — $(date '+%Y-%m-%d %H:%M')"
  # Each check runs in its own command substitution in THIS shell: a check
  # that dies (exit, unbound variable, missing function) is caught by the
  # substitution's exit status and rendered as ✘, so the report can never
  # be silently truncated and still end in "ready".
  for chk in ${JETSON_STATUS_CHECKS}; do
    if out="$("${chk}" 2>/dev/null)"; then :; else
      out="${out}"$'\n'"bad"$'\t'"internal: ${chk} failed — please report this"
    fi
    while IFS=$'\t' read -r level msg; do
      case "${level}" in
        ok)   _ok "${msg}" ;;
        warn) _warn "${msg}"; warn=$((warn+1)) ;;
        bad)  _bad "${msg}"; bad=$((bad+1)) ;;
      esac
    done <<<"${out}"
  done
  printf '\n' >&2
  if (( bad > 0 )); then
    printf '[jetson] %d blocker(s) — fix the ✘ lines first.\n' "${bad}" >&2; exit 1
  elif (( warn > 0 )) && [[ -n "${strict}" ]]; then
    printf '[jetson] --strict: %d warning(s) treated as failure.\n' "${warn}" >&2; exit 1
  fi
  printf '[jetson] ready. Typical order: ./jetson prepare → REC → ./jetson flash\n' >&2
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  _no_args() { (( $# == 0 )) || { printf 'jetson: %s takes no arguments (got: %s)\n\n' "${cmd}" "$*" >&2; _usage; exit 2; }; }
  case "${cmd}" in
    status)   [[ $# -eq 0 || ( $# -eq 1 && "$1" == "--strict" ) ]] || { _usage; exit 2; }; cmd_status "$@" ;;
    prepare)  cmd_prepare "$@" ;;
    wait-rec) (( $# <= 1 )) || { _usage; exit 2; }; cmd_wait_rec "$@" ;;
    flash)    _no_args "$@"; cmd_flash ;;
    all)      (( $# <= 1 )) || { _usage; exit 2; }; cmd_all "$@" ;;
    teardown) _no_args "$@"; cmd_teardown ;;
    purge)    cmd_purge "$@" ;;
    ""|-h|--help|help) _usage; [[ -z "${cmd}" || "${cmd}" == "help" || "${cmd}" == -* ]] && exit 0 ;;
    *) printf 'jetson: unknown command: %s\n\n' "${cmd}" >&2; _usage; exit 2 ;;
  esac
}

main "$@"
