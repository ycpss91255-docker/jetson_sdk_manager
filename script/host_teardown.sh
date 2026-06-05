#!/usr/bin/env bash
# host_teardown.sh — reverse host_setup.sh's mutations on the HOST.
#
# Run this on the HOST (not inside the container) when you are DONE flashing
# and want to hand the machine back to its normal configuration in the same
# boot, instead of waiting for a reboot. It undoes, in reverse, what
# host_setup.sh + nm_flash_guard.sh changed:
#
#   1. /srv/jetson_l4t bind   — unmount the NFS export bridge (host_setup 5/5)
#   2. usbfs_memory_mb        — restore the kernel default (16 MB)
#   3. USB autosuspend        — restore the kernel default (2)
#   4. NetworkManager guard   — remove the flash-unmanaged file and stop a
#                               running `nm_flash_guard auto` watcher
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

# Overridable for tests; defaults are the real kernel sysfs paths / tools.
USBCORE_PARAMS="${USBCORE_PARAMS:-/sys/module/usbcore/parameters}"
# Kernel defaults host_setup.sh overrode. autosuspend defaults to 2 (seconds);
# usbfs_memory_mb defaults to 16 (MB). We restore those rather than try to
# remember the pre-setup values (host_setup.sh didn't save them, and both are
# boot-reset anyway). Overridable so a site with a different baseline can adjust.
USBCORE_AUTOSUSPEND_DEFAULT="${USBCORE_AUTOSUSPEND_DEFAULT:-2}"
USBFS_MEMORY_MB_DEFAULT="${USBFS_MEMORY_MB_DEFAULT:-16}"
# NFS export bridge (host_setup 5/5). Must match host_setup.sh's L4T_EXPORT_DIR.
L4T_EXPORT_DIR="${L4T_EXPORT_DIR:-/srv/jetson_l4t}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"
MOUNTPOINT_BIN="${MOUNTPOINT_BIN:-mountpoint}"
# nm_flash_guard.sh handles both the guard file and the auto-watcher pidfile.
NM_GUARD_BIN="${NM_GUARD_BIN:-${_HERE}/nm_flash_guard.sh}"
# Mirror nm_flash_guard.sh's watcher pidfile default so we can stop a running
# `auto` watcher (it re-enables NM on its own, but a same-boot teardown wants
# it gone now rather than after its timeout).
NM_GUARD_PIDFILE="${NM_GUARD_PIDFILE:-${TMPDIR:-/tmp}/nm-jetson-flash-guard.pid}"

_step() { printf '\n\033[36m[host-teardown] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }

main() {
  _step "1/4 Unmounting the NFS export bridge ${L4T_EXPORT_DIR}"
  if "${MOUNTPOINT_BIN}" -q "${L4T_EXPORT_DIR}"; then
    sudo "${UMOUNT_BIN}" "${L4T_EXPORT_DIR}"
    _ok "${L4T_EXPORT_DIR} unmounted"
  else
    _ok "${L4T_EXPORT_DIR} not a mountpoint — nothing to unmount"
  fi

  _step "2/4 Restoring usbfs buffer to the kernel default (${USBFS_MEMORY_MB_DEFAULT} MB)"
  if [[ -w "${USBCORE_PARAMS}/usbfs_memory_mb" ]] || sudo test -e "${USBCORE_PARAMS}/usbfs_memory_mb"; then
    echo "${USBFS_MEMORY_MB_DEFAULT}" | sudo tee "${USBCORE_PARAMS}/usbfs_memory_mb" >/dev/null
    _ok "usbfs_memory_mb = ${USBFS_MEMORY_MB_DEFAULT}"
  else
    _ok "usbcore not loaded — usbfs_memory_mb left as-is (boot-reset)"
  fi

  _step "3/4 Restoring USB autosuspend to the kernel default (${USBCORE_AUTOSUSPEND_DEFAULT})"
  if [[ -w "${USBCORE_PARAMS}/autosuspend" ]] || sudo test -e "${USBCORE_PARAMS}/autosuspend"; then
    echo "${USBCORE_AUTOSUSPEND_DEFAULT}" | sudo tee "${USBCORE_PARAMS}/autosuspend" >/dev/null
    _ok "autosuspend = ${USBCORE_AUTOSUSPEND_DEFAULT}"
  else
    _ok "usbcore not loaded — autosuspend left as-is (boot-reset)"
  fi

  _step "4/4 Restoring NetworkManager control of USB gadget interfaces"
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

  cat >&2 <<'EOF'

[host-teardown] Done. The host is back to its normal configuration.

Note: QEMU binfmt and the nfsd module are intentionally left in place
(harmless / shared) — a reboot clears them along with everything else.
EOF
}

main "$@"
