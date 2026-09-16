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

# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"

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
  prepare                Host setup + download BSP + build flash images (~30 min, no Jetson needed).
  wait-rec [seconds]     Show how to enter recovery (REC) and wait until the board appears.
  flash                  Write the images to a Jetson that is in recovery (~10 min).
  all                    prepare → wait-rec → flash, stopping at the first problem.
  teardown               Undo the host changes from prepare (same boot; a reboot does the same).
  purge [--yes] [--keep-downloads]
                         Remove everything prepare produced, incl. the data store. Then rm -rf is safe.

Typical first flash:   ./jetson prepare   →   put the board in REC   →   ./jetson flash
USAGE
}

# ── preflight helpers ────────────────────────────────────────────────

# _prepared_marker — path of the .prepared.yaml prepare.sh wrote, if any.
_prepared_marker() {
  find "${L4T_REPO_ROOT}/data/jetson_l4t" -maxdepth 3 -name .prepared.yaml 2>/dev/null | head -n1
}

# _phase_done <phase> — yq is not a host dependency, so read the marker
# with grep: mikefarah yq writes a block list ("  - images"); hand-written
# fixtures may use flow style ("phases: [bsp, images]"). Accept both.
_phase_done() {
  local marker
  marker="$(_prepared_marker)"
  [[ -n "${marker}" ]] || return 1
  grep -qE "^[[:space:]]*-[[:space:]]*$1[[:space:]]*$|^phases:.*[[:space:][]$1[],[:space:]]" "${marker}"
}

# _recovery_line — the lsusb line of the first Jetson in recovery, or empty.
_recovery_line() {
  local pid line
  while IFS=$'\t' read -r pid line; do
    if jetson_pid_is_recovery "${pid}"; then printf '%s\n' "${line}"; return 0; fi
  done < <(jetson_list_devices)
  return 1
}

_rec_instructions() {
  cat >&2 <<'REC'
  Put the Jetson into recovery (REC / APX) mode:
    1. Disconnect the power supply.
    2. USB-C cable: Jetson FRONT panel (the port next to the buttons) ↔ this host.
    3. Hold the REC button, reconnect power, release REC after ~2 s.
  The board then enumerates as USB 0955:7023 (AGX Orin) / 7323 (Orin NX) / 7523 (Orin Nano).
REC
}

# ── commands ─────────────────────────────────────────────────────────

cmd_flash() {
  _say "flash — preflight"
  local rec
  if ! rec="$(_recovery_line)"; then
    _rec_instructions
    _die "no Jetson in recovery on the USB bus" "run ./jetson wait-rec, then ./jetson flash again"
  fi
  _ok "Jetson in recovery: ${rec}"
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

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "${cmd}" in
    flash)    cmd_flash "$@" ;;
    ""|-h|--help|help) _usage; [[ -z "${cmd}" || "${cmd}" == "help" || "${cmd}" == -* ]] && exit 0 ;;
    *) printf 'jetson: unknown command: %s\n\n' "${cmd}" >&2; _usage; exit 2 ;;
  esac
}

main "$@"
