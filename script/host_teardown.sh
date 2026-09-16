#!/usr/bin/env bash
# host_teardown.sh — reverse host_setup.sh's mutations on the HOST.
#
# Run this on the HOST (not inside the container) when you are DONE flashing
# and want to hand the machine back to its normal configuration in the same
# boot, instead of waiting for a reboot. It undoes, in reverse, what
# host_setup.sh + nm_flash_guard.sh + usb_ss_guard.sh changed:
#
#   1. host NFS export        — unexport the L4T tree from the host
#                               nfs-kernel-server (host_setup 6/7, #101). First,
#                               because the kernel nfsd pins an exported
#                               directory and the bridge umount below would
#                               fail with "target is busy"
#   2. /srv/jetson_l4t bind   — unmount the NFS export bridge (host_setup 5/7)
#                               and drop the empty directory it lived in
#   3. data/jetson_l4t store  — unmount the in-repo ext4 image / bind (#93,
#                               host_setup 0/7). The image and its marker
#                               stay; `clean.sh purge` is what deletes them.
#   4. usbfs_memory_mb        — restore the kernel default (16 MB)
#   5. USB autosuspend        — restore the kernel default (2)
#   6. NetworkManager guard   — remove the flash-unmanaged file and stop a
#                               running `nm_flash_guard auto` watcher
#   7. USB SuperSpeed guard   — `usb_ss_guard.sh enable`: stops its own
#                               `auto` watcher and re-enables the SS half
#                               of the Jetson's connector (#100)
#
# What it does NOT undo: the QEMU binfmt registration (harmless to leave) and
# the nfsd kernel module (other services may rely on it; unloading is risky).
# Both are boot-scoped anyway, so a reboot clears everything host_setup.sh did.
#
# Safe to re-run — every step is idempotent and a no-op when the thing was
# never set up. The kernel bits need root, so you may be prompted for sudo.
#
# This is a convenience for same-boot cleanup only; a plain reboot is always a
# valid alternative since none of host_setup.sh's changes are persistent.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO="$(cd "${_HERE}/.." && pwd)"
# Overridable so the bats suite can point data/ at a tmpdir.
L4T_REPO_ROOT="${L4T_REPO_ROOT:-${_REPO}}"
L4T_STORE_DATA_DIR="${L4T_REPO_ROOT}/data/jetson_l4t"
L4T_STORE_MARKER="${L4T_REPO_ROOT}/data/.l4t_store"

# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/nfs_export.sh
. "${_HERE}/lib/nfs_export.sh"

# Overridable for tests; defaults are the real kernel sysfs paths / tools.
USBCORE_PARAMS="${USBCORE_PARAMS:-/sys/module/usbcore/parameters}"
# Kernel defaults host_setup.sh overrode. autosuspend defaults to 2 (seconds);
# usbfs_memory_mb defaults to 16 (MB). We restore those rather than try to
# remember the pre-setup values (host_setup.sh didn't save them, and both are
# boot-reset anyway). Overridable so a site with a different baseline can adjust.
USBCORE_AUTOSUSPEND_DEFAULT="${USBCORE_AUTOSUSPEND_DEFAULT:-2}"
USBFS_MEMORY_MB_DEFAULT="${USBFS_MEMORY_MB_DEFAULT:-16}"
# NFS export bridge (host_setup 5/7). Must match host_setup.sh's L4T_EXPORT_DIR.
L4T_EXPORT_DIR="${L4T_EXPORT_DIR:-/srv/jetson_l4t}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"
MOUNTPOINT_BIN="${MOUNTPOINT_BIN:-mountpoint}"
RMDIR_BIN="${RMDIR_BIN:-rmdir}"
# nm_flash_guard.sh handles both the guard file and the auto-watcher pidfile.
NM_GUARD_BIN="${NM_GUARD_BIN:-${_HERE}/nm_flash_guard.sh}"
# Mirror nm_flash_guard.sh's watcher pidfile default so we can stop a running
# `auto` watcher (it re-enables NM on its own, but a same-boot teardown wants
# it gone now rather than after its timeout).
NM_GUARD_PIDFILE="${NM_GUARD_PIDFILE:-${TMPDIR:-/tmp}/nm-jetson-flash-guard.pid}"
# usb_ss_guard.sh (#100): `enable` stops its own watcher (verified through
# /proc) and restores the port it recorded, so no state path is known here.
USB_SS_GUARD_BIN="${USB_SS_GUARD_BIN:-${_HERE}/usb_ss_guard.sh}"

_step() { printf '\n\033[36m[host-teardown] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }

# _unexport_l4t_trees — step 1 body. Unexport every prepared tree found under
# data/jetson_l4t (usually one; after a board switch without clean.sh there
# may be two — unexporting both is harmless). No-op without exportfs, or when
# nothing is prepared / the store is already down.
_unexport_l4t_trees() {
  local l4t n=0
  while IFS= read -r l4t; do
    [[ -n "${l4t}" ]] || continue
    n=$((n+1))
    nfs_export_off "${l4t}"
  done < <(nfs_export_l4t_dirs)
  (( n > 0 )) || _ok "no prepared L4T tree under data/jetson_l4t — nothing to unexport"
}

main() {
  _step "1/7 Unexporting the L4T tree from the host NFS server (if the host runs one)"
  _unexport_l4t_trees

  _step "2/7 Unmounting the NFS export bridge ${L4T_EXPORT_DIR}"
  if "${MOUNTPOINT_BIN}" -q "${L4T_EXPORT_DIR}"; then
    sudo "${UMOUNT_BIN}" "${L4T_EXPORT_DIR}"
    _ok "${L4T_EXPORT_DIR} unmounted"
  else
    _ok "${L4T_EXPORT_DIR} not a mountpoint — nothing to unmount"
  fi
  # host_setup mkdir'd the bridge dir; take it back out so the host is left
  # exactly as found. Only when empty — anything inside is not ours.
  if [[ -d "${L4T_EXPORT_DIR}" ]] && [[ -z "$(ls -A "${L4T_EXPORT_DIR}" 2>/dev/null)" ]]; then
    sudo "${RMDIR_BIN}" "${L4T_EXPORT_DIR}"
    _ok "removed empty ${L4T_EXPORT_DIR}"
  fi

  _step "3/7 Unmounting the L4T data store ${L4T_STORE_DATA_DIR}"
  # Order matters: /srv is a bind OF this mount, so it had to go first.
  # umount detaches the loop device by itself (mount -o loop sets autoclear).
  if ! "${MOUNTPOINT_BIN}" -q "${L4T_STORE_DATA_DIR}"; then
    _ok "${L4T_STORE_DATA_DIR} not a mountpoint — native checkout or already down"
  elif [[ ! -f "${L4T_STORE_MARKER}" ]]; then
    # A mount host_setup.sh did not record is not ours to take down (#93
    # review). Leave it and say so; the user unmounts it or re-runs setup
    # (which recovers the marker when the image is there).
    _ok "${L4T_STORE_DATA_DIR} is mounted but there is no data/.l4t_store marker — not ours, leaving it mounted"
  else
    sudo "${UMOUNT_BIN}" "${L4T_STORE_DATA_DIR}"
    _ok "${L4T_STORE_DATA_DIR} unmounted (image + marker kept; clean.sh purge removes them)"
  fi

  _step "4/7 Restoring usbfs buffer to the kernel default (${USBFS_MEMORY_MB_DEFAULT} MB)"
  if [[ -w "${USBCORE_PARAMS}/usbfs_memory_mb" ]] || sudo test -e "${USBCORE_PARAMS}/usbfs_memory_mb"; then
    echo "${USBFS_MEMORY_MB_DEFAULT}" | sudo tee "${USBCORE_PARAMS}/usbfs_memory_mb" >/dev/null
    _ok "usbfs_memory_mb = ${USBFS_MEMORY_MB_DEFAULT}"
  else
    _ok "usbcore not loaded — usbfs_memory_mb left as-is (boot-reset)"
  fi

  _step "5/7 Restoring USB autosuspend to the kernel default (${USBCORE_AUTOSUSPEND_DEFAULT})"
  if [[ -w "${USBCORE_PARAMS}/autosuspend" ]] || sudo test -e "${USBCORE_PARAMS}/autosuspend"; then
    echo "${USBCORE_AUTOSUSPEND_DEFAULT}" | sudo tee "${USBCORE_PARAMS}/autosuspend" >/dev/null
    _ok "autosuspend = ${USBCORE_AUTOSUSPEND_DEFAULT}"
  else
    _ok "usbcore not loaded — autosuspend left as-is (boot-reset)"
  fi

  _step "6/7 Restoring NetworkManager control of USB gadget interfaces"
  # Stop a running `nm_flash_guard auto` watcher first so it can't race the
  # `enable` below or re-toggle later. The watcher re-enables NM itself, but a
  # same-boot teardown wants it gone now instead of after its timeout.
  if [[ -e "${NM_GUARD_PIDFILE}" ]]; then
    local _wpid
    _wpid="$(cat "${NM_GUARD_PIDFILE}" 2>/dev/null || true)"
    if [[ -n "${_wpid}" ]] && kill -0 "${_wpid}" 2>/dev/null; then
      kill "${_wpid}" 2>/dev/null || true
      _ok "stopped nm_flash_guard auto watcher (PID ${_wpid})"
    fi
    rm -f "${NM_GUARD_PIDFILE}" 2>/dev/null || true
  fi
  # `enable` removes the guard file and reloads NM. Idempotent: a no-op when no
  # guard file is present.
  if [[ -x "${NM_GUARD_BIN}" ]]; then
    "${NM_GUARD_BIN}" enable
  else
    printf '  nm_flash_guard.sh not found at %s — skip NM restore\n' "${NM_GUARD_BIN}" >&2
  fi

  _step "7/7 Re-enabling the SuperSpeed half of the Jetson's USB connector"
  # `enable` stops a running `auto` watcher itself (only a PID /proc
  # confirms is a usb_ss_guard watcher) and is a no-op without state.
  if [[ -x "${USB_SS_GUARD_BIN}" ]]; then
    "${USB_SS_GUARD_BIN}" enable
  else
    printf '  usb_ss_guard.sh not found at %s — skip USB SuperSpeed restore\n' "${USB_SS_GUARD_BIN}" >&2
  fi

  cat >&2 <<'EOF'

[host-teardown] Done. The host is back to its normal configuration.

Note: QEMU binfmt and the nfsd module are intentionally left in place
(harmless / shared) — a reboot clears them along with everything else.
EOF
}

main "$@"
