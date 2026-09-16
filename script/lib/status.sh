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
# Must match usb_ss_guard.sh's STATE_FILE default (#100).
USB_SS_GUARD_STATE="${USB_SS_GUARD_STATE:-/tmp/usb-ss-guard.state}"

_st() { printf '%s\t%s\n' "$1" "$2"; }

# ── Jetson on the USB bus ────────────────────────────────────────────
# status_recovery_lines — one lsusb line per Jetson in recovery (0..n lines).
status_recovery_lines() {
  local pid line
  while IFS=$'\t' read -r pid line; do
    [[ -n "${pid}" ]] && jetson_pid_is_recovery "${pid}" && printf '%s\n' "${line}"
  done < <(jetson_list_devices)
  return 0
}

status_jetson() {
  local pid line n=0 nrec=0 rec="" booted="" other=""
  while IFS=$'\t' read -r pid line; do
    [[ -n "${pid}" ]] || continue
    n=$((n+1))
    if jetson_pid_is_recovery "${pid}"; then rec="${line}"; nrec=$((nrec+1))
    elif [[ "${pid,,}" == "${JETSON_BOOTED_PID}" ]]; then booted="${line}"
    else other="${line}"; fi
  done < <(jetson_list_devices)
  if (( n == 0 )); then
    _st warn "no Jetson on the USB bus — connect the FRONT USB-C port and enter REC (./jetson wait-rec)"
    return 0
  fi
  if (( nrec > 1 )); then
    _st warn "${n} NVIDIA devices on the bus, ${nrec} in recovery — flash refuses until only one is connected"
  elif (( n > 1 )); then
    _st warn "${n} NVIDIA devices on the bus — make sure you flash the right one"
  fi
  if [[ -n "${rec}" ]]; then
    _st ok "Jetson in recovery: ${rec}"
  elif [[ -n "${booted}" ]]; then
    _st warn "Jetson is booted (0955:${JETSON_BOOTED_PID}), not in recovery — enter REC before ./jetson flash"
  else
    _st warn "NVIDIA device present but not a known Jetson state: ${other}"
  fi
}

# ── prepare progress (.prepared.yaml) ────────────────────────────────
# 'network' is deliberately absent: prepare.sh records it only when
# jetson.yaml asks for a static profile (DHCP is the default), so it is not
# a completeness criterion. 'images' is what flash needs.
STATUS_PHASES="bsp rootfs binaries user images"

# status_markers — every .prepared.yaml under data/jetson_l4t, one per line.
# More than one means two L4T trees were prepared (board switch without
# clean.sh l4t); callers must not silently pick one.
status_markers() {
  find "${L4T_REPO_ROOT}/data/jetson_l4t" -maxdepth 3 -name .prepared.yaml 2>/dev/null | sort
}

# status_phase_done <marker> <phase> — yq is not a host dependency, so the
# marker is read with sed: strip inline comments and quotes, then match a
# block-list item ("  - images") or a flow-list member ("phases: [bsp, images]").
status_phase_done() {
  sed -E 's/[[:space:]]+#.*$//; s/["'"'"']//g' "$1" \
    | grep -qE "^[[:space:]]*-[[:space:]]*$2[[:space:]]*$|^phases:.*[[:space:][]$2[],[:space:]]"
}

status_prepare() {
  local marker missing="" p n
  n="$(status_markers | grep -c . || true)"
  if (( n == 0 )); then
    _st warn "prepare has not run — put the board in recovery, then ./jetson prepare (~30 min; its last step reads the board spec over USB)"
    return 0
  elif (( n > 1 )); then
    _st warn "more than one prepared L4T tree under data/jetson_l4t (${n}) — ambiguous; ./script/clean.sh l4t and re-run ./jetson prepare"
    return 0
  fi
  marker="$(status_markers)"
  for p in ${STATUS_PHASES}; do
    status_phase_done "${marker}" "${p}" || missing="${missing} ${p}"
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
  # A status query must not create anything: probe the nearest existing
  # parent when data/jetson_l4t is not there yet.
  local probe="${data}" note=""
  if [[ ! -e "${probe}" ]]; then
    note=" (data/jetson_l4t not created yet — prepare does that)"
    probe="${L4T_REPO_ROOT}/data"; [[ -e "${probe}" ]] || probe="${L4T_REPO_ROOT}"
  fi
  fstype="$(store_fstype_of "${probe}")"
  if store_fstype_is_unix "${fstype:-?}"; then
    _st ok "data store: native ${fstype:-unix} filesystem, nothing to mount${note}"
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

# ── USB SuperSpeed guard (#100) ──────────────────────────────────────
# The guard parks the SS half of the Jetson's connector for the flash and
# its watcher restores it on boot / timeout. A state file outside a flash
# means a connector is still at USB 2 — worth a warning, never a blocker.
status_usb_ss_guard() {
  local port
  if [[ -f "${USB_SS_GUARD_STATE}" ]]; then
    port="$(head -n1 "${USB_SS_GUARD_STATE}" 2>/dev/null || true)"
    _st warn "USB SuperSpeed half ${port##*/} is disabled by usb_ss_guard — expected during a flash; otherwise ./script/usb_ss_guard.sh enable (or ./jetson teardown)"
  else
    _st ok "USB SuperSpeed guard idle — ./jetson flash parks the connector's SS half for the initrd link (usb_ss_guard.sh auto)"
  fi
}

# ── jetson.yaml ──────────────────────────────────────────────────────

# _status_yaml_scalar <file> <key> — first "key: value" scalar, with the
# inline comment and surrounding single/double quotes stripped. A small,
# deliberately limited reader (no yq on the host); values are never echoed
# by callers except board / storage.
_status_yaml_scalar() {
  sed -nE "s/^[[:space:]]*$2:[[:space:]]*(.*)$/\1/p" "$1" | head -n1 \
    | sed -E 's/[[:space:]]+#.*$//; s/^#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

status_config() {
  local cfg="${L4T_REPO_ROOT}/jetson.yaml" target board storage pw
  if [[ ! -e "${cfg}" ]]; then
    _st bad "jetson.yaml missing — ln -sf config/jetson/<preset>.yaml jetson.yaml"
    return 0
  fi
  target="$(readlink "${cfg}" 2>/dev/null || echo "${cfg}")"
  board="$(_status_yaml_scalar "${cfg}" board)"
  storage="$(_status_yaml_scalar "${cfg}" device)"
  if [[ -z "${board}" || -z "${storage}" ]]; then
    _st warn "config: ${target##*/} — could not read hardware.board / storage.device; compare with config/jetson/_example.yaml"
  else
    _st ok "config: ${target##*/} (board ${board}, storage ${storage})"
  fi
  pw="$(_status_yaml_scalar "${cfg}" password)"
  if [[ "${pw}" == "jetson" ]]; then
    _st warn "default password in jetson.yaml — change it before flashing, or run passwd on the board right after"
  fi
}
