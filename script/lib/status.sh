#!/usr/bin/env bash
# status.sh — the checks behind `./jetson status` (#95).
#
# Each status_* function prints one or more lines "<level>\t<message>",
# level ∈ ok | warn | bad, and never exits the shell. jetson.sh renders
# them (✔ / ⚠ / ✘) and turns any `bad` into a non-zero exit. Inputs are
# read through overridable paths / binaries so the bats suite can drive
# every branch without root or hardware.

set -euo pipefail

# Callers source errors.sh, usb.sh and store.sh first (jetson.sh does).

L4T_REPO_ROOT="${L4T_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
USBCORE_PARAMS="${USBCORE_PARAMS:-/sys/module/usbcore/parameters}"
NFSD_SYSFS="${NFSD_SYSFS:-/sys/module/nfsd}"
STATUS_MOUNTPOINT_BIN="${STATUS_MOUNTPOINT_BIN:-mountpoint}"

_st() { printf '%s\t%s\n' "$1" "$2"; }

# ── Jetson on the USB bus ────────────────────────────────────────────
status_jetson() {
  local pid line n=0 rec="" booted="" other=""
  while IFS=$'\t' read -r pid line; do
    [[ -n "${pid}" ]] || continue
    n=$((n+1))
    if jetson_pid_is_recovery "${pid}"; then rec="${line}"
    elif [[ "${pid,,}" == "${JETSON_BOOTED_PID}" ]]; then booted="${line}"
    else other="${line}"; fi
  done < <(jetson_list_devices)
  if (( n == 0 )); then
    _st warn "no Jetson on the USB bus — connect the FRONT USB-C port and enter REC (./jetson wait-rec)"
    return 0
  fi
  (( n > 1 )) && _st warn "${n} NVIDIA devices on the bus — make sure you flash the right one"
  if [[ -n "${rec}" ]]; then
    _st ok "Jetson in recovery: ${rec}"
  elif [[ -n "${booted}" ]]; then
    _st warn "Jetson is booted (0955:${JETSON_BOOTED_PID}), not in recovery — enter REC before ./jetson flash"
  else
    _st warn "NVIDIA device present but not a known Jetson state: ${other}"
  fi
}

# ── prepare progress (.prepared.yaml) ────────────────────────────────
STATUS_PHASES="bsp rootfs binaries user network images"

_status_marker() {
  find "${L4T_REPO_ROOT}/data/jetson_l4t" -maxdepth 3 -name .prepared.yaml 2>/dev/null | head -n1
}

# _status_phase_done <marker> <phase> — block list or flow style, no yq.
_status_phase_done() {
  grep -qE "^[[:space:]]*-[[:space:]]*$2[[:space:]]*$|^phases:.*[[:space:][]$2[],[:space:]]" "$1"
}

status_prepare() {
  local marker missing="" p
  marker="$(_status_marker)"
  if [[ -z "${marker}" ]]; then
    _st warn "prepare has not run — ./jetson prepare (~30 min, no board needed)"
    return 0
  fi
  for p in ${STATUS_PHASES}; do
    _status_phase_done "${marker}" "${p}" || missing="${missing} ${p}"
  done
  if [[ -z "${missing}" ]]; then
    _st ok "prepare complete: ${STATUS_PHASES// /, } (flash images ready)"
  else
    _st warn "prepare incomplete — missing:${missing}; re-run ./jetson prepare (it resumes)"
  fi
}

# ── L4T data store ───────────────────────────────────────────────────
status_store() {
  local data="${L4T_REPO_ROOT}/data/jetson_l4t" marker="${L4T_REPO_ROOT}/data/.l4t_store"
  local backend fstype
  if [[ -f "${marker}" ]]; then
    backend="$(store_marker_read "${marker}" backend 2>/dev/null || echo '?')"
    if "${STATUS_MOUNTPOINT_BIN}" -q "${data}"; then
      _st ok "data store: ${backend}, mounted on data/jetson_l4t"
    else
      _st bad "data store: ${backend} recorded but not mounted (reboot?) — ./jetson prepare re-runs host_setup.sh"
    fi
    return 0
  fi
  mkdir -p "${data}" 2>/dev/null || true
  fstype="$(store_fstype_of "${data}")"
  if store_fstype_is_unix "${fstype:-?}"; then
    _st ok "data store: native ${fstype:-unix} filesystem, nothing to mount"
  else
    _st bad "data/jetson_l4t is on ${fstype} (cannot keep setuid/ownership) — ./jetson prepare sets up the in-repo ext4 image"
  fi
}

# ── kernel prerequisites ─────────────────────────────────────────────
status_kernel() {
  local a m
  if [[ -d "${NFSD_SYSFS}" ]]; then
    _st ok "nfsd module loaded"
  else
    _st bad "nfsd module not loaded — ./jetson prepare (host_setup.sh) loads it"
  fi
  a="$(cat "${USBCORE_PARAMS}/autosuspend" 2>/dev/null || echo '?')"
  m="$(cat "${USBCORE_PARAMS}/usbfs_memory_mb" 2>/dev/null || echo '?')"
  if [[ "${a}" == "-1" ]] && [[ "${m}" =~ ^[0-9]+$ ]] && (( m >= 2048 )); then
    _st ok "USB: autosuspend off, usbfs buffer ${m} MB"
  else
    _st warn "USB params at defaults (autosuspend=${a}, usbfs_memory_mb=${m}) — flash may stall; host_setup.sh sets them"
  fi
}

# ── jetson.yaml ──────────────────────────────────────────────────────
status_config() {
  local cfg="${L4T_REPO_ROOT}/jetson.yaml" target board storage pw
  if [[ ! -e "${cfg}" ]]; then
    _st bad "jetson.yaml missing — ln -sf config/jetson/<preset>.yaml jetson.yaml"
    return 0
  fi
  target="$(readlink "${cfg}" 2>/dev/null || echo "${cfg}")"
  board="$(sed -nE 's/^[[:space:]]*board:[[:space:]]*([^[:space:]#]+).*/\1/p' "${cfg}" | head -n1)"
  storage="$(sed -nE 's/^[[:space:]]*device:[[:space:]]*([^[:space:]#]+).*/\1/p' "${cfg}" | head -n1)"
  _st ok "config: ${target##*/} (board ${board:-?}, storage ${storage:-?})"
  pw="$(sed -nE 's/^[[:space:]]*password:[[:space:]]*([^[:space:]#]+).*/\1/p' "${cfg}" | head -n1)"
  if [[ "${pw}" == "jetson" ]]; then
    _st warn "default password in jetson.yaml — change it before flashing, or run passwd on the board right after"
  fi
}
