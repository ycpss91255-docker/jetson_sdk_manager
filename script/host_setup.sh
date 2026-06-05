#!/usr/bin/env bash
# host_setup.sh — one-shot HOST prerequisites for the factory-flash workflow.
#
# Run this on the HOST (not inside the container), once per boot, BEFORE
# `make run -- -t prepare` / `-t flash` — ideally before connecting the
# Jetson. Everything here touches the host kernel or Docker and therefore
# CANNOT be done from inside the container (which shares the host kernel):
#
#   1. QEMU binfmt              — run the BSP's ARM64 tools during prepare
#   2. nfsd kernel module       — l4t_initrd_flash serves the flash payload
#                                 to the Jetson's initrd over a local NFS export
#   3. USB autosuspend off      — stop the kernel parking the port mid-write
#   4. usbfs_memory_mb = 2048   — stop tegrarcm / NFS bulk writes stalling
#   5. /srv/jetson_l4t bind     — bridge the NFS export path into the host
#                                 mount namespace (see the step-5 comment)
# NetworkManager is the other half of a reliable flash, but it is a
# FLASH-SCOPED toggle (NM must ignore the Jetson USB gadget while flashing,
# but manage it once the board boots so the host gets 192.168.55.100). That
# lives in its own script, NOT here — one command handles both edges:
#   ./script/nm_flash_guard.sh auto   # before `make run -- -t flash`
# Without it the in-container flash stalls mid-transfer — see issue #48.
#
# Safe to re-run. The kernel bits need root, so you may be prompted for sudo.
# These settings reset on reboot; re-run after each boot (or persist nfsd via
# `echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf`).
#
# NOTE: the USB autosuspend default only applies to devices that enumerate
# AFTER it is set, so run this before putting the Jetson into recovery. If the
# Jetson is already connected, power-cycle it back into recovery afterwards.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO="$(cd "${_HERE}/.." && pwd)"

# Overridable for tests; defaults are the real kernel sysfs paths / tools.
USBCORE_PARAMS="${USBCORE_PARAMS:-/sys/module/usbcore/parameters}"
QEMU_IMAGE="${QEMU_IMAGE:-multiarch/qemu-user-static}"
USBFS_MEMORY_MB="${USBFS_MEMORY_MB:-2048}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
# NFS export bridge (step 5). L4T_EXPORT_DIR must match volume.sh's
# L4T_ROOT_DEFAULT (/srv/jetson_l4t) and setup.conf mount_6's container path.
L4T_EXPORT_SRC="${L4T_EXPORT_SRC:-${_REPO}/data/jetson_l4t}"
# Track whether the caller redirected the export dir (tests do) so the
# path-contract check below only fires for the real, un-overridden path —
# a tmpdir override is not a contract violation.
_L4T_EXPORT_DIR_OVERRIDDEN="${L4T_EXPORT_DIR+yes}"
L4T_EXPORT_DIR="${L4T_EXPORT_DIR:-/srv/jetson_l4t}"
MOUNT_BIN="${MOUNT_BIN:-mount}"
MOUNTPOINT_BIN="${MOUNTPOINT_BIN:-mountpoint}"
# Where to read volume.sh's canonical export path for the contract check.
# Overridable so the smoke test can point at a fixture.
VOLUME_LIB="${VOLUME_LIB:-${_HERE}/lib/volume.sh}"

_step() { printf '\n\033[36m[host-setup] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }
_warn() { printf '  \033[33mwarning: %s\033[0m\n' "$1" >&2; }

# _volume_export_default — echo volume.sh's L4T_ROOT_DEFAULT without sourcing
# it (volume.sh does `set -euo pipefail` and requires errors.sh). Returns
# empty if it can't be read; the caller then skips the contract check rather
# than warning on a false negative.
_volume_export_default() {
  [[ -r "${VOLUME_LIB}" ]] || return 0
  sed -n 's/^L4T_ROOT_DEFAULT="\(.*\)"$/\1/p' "${VOLUME_LIB}" | head -n1
}

# _assert_path_contract — the export path lives in three places that must
# agree (volume.sh L4T_ROOT_DEFAULT, setup.conf mount_6's container path, and
# this script's L4T_EXPORT_DIR). They are wired up by hand, so a future edit to
# one alone silently breaks the NFS export resolution (issue #52). Warn loudly
# if this script's L4T_EXPORT_DIR has drifted from volume.sh's default so the
# mismatch is caught at run time instead of in a failed flash.
_assert_path_contract() {
  local vol_default
  vol_default="$(_volume_export_default)"
  [[ -n "${vol_default}" ]] || return 0
  # Skip when the caller explicitly redirected the path (e.g. tests).
  [[ -z "${_L4T_EXPORT_DIR_OVERRIDDEN}" ]] || return 0
  if [[ "${L4T_EXPORT_DIR}" != "${vol_default}" ]]; then
    _warn "L4T_EXPORT_DIR (${L4T_EXPORT_DIR}) != volume.sh L4T_ROOT_DEFAULT (${vol_default})"
    _warn "these must match (and setup.conf mount_6's container path too) or the NFS export won't resolve — see issue #52"
  fi
}

main() {
  _step "1/5 Registering QEMU binfmt (ARM64 emulation for prepare)"
  if command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    "${DOCKER_BIN}" run --rm --privileged "${QEMU_IMAGE}" --reset -p yes >/dev/null
    _ok "qemu-user-static registered"
  else
    printf '  docker not found on PATH — install Docker, then re-run\n' >&2
  fi

  _step "2/5 Loading nfsd kernel module (NFS export for flash)"
  sudo modprobe nfsd
  _ok "nfsd loaded"

  _step "3/5 Disabling USB autosuspend (prevents mid-flash stalls)"
  echo -1 | sudo tee "${USBCORE_PARAMS}/autosuspend" >/dev/null
  _ok "autosuspend = -1"

  _step "4/5 Raising usbfs buffer to ${USBFS_MEMORY_MB} MB (prevents bulk-write stalls)"
  echo "${USBFS_MEMORY_MB}" | sudo tee "${USBCORE_PARAMS}/usbfs_memory_mb" >/dev/null
  _ok "usbfs_memory_mb = ${USBFS_MEMORY_MB}"

  _step "5/5 Bridging the NFS export path ${L4T_EXPORT_DIR} into the host namespace"
  _assert_path_contract
  # l4t_initrd_flash serves the payload from ${L4T_EXPORT_DIR} (volume.sh
  # L4T_ROOT_DEFAULT). The container bind-mounts ./data/jetson_l4t there, but
  # the kernel nfsd that actually answers the Jetson resolves paths in the
  # HOST mount namespace — where that container-only path is absent, so the
  # initrd's mount.nfs dies with "No such file or directory" (issue #52).
  # Mirror the same directory into the host namespace so both see identical
  # content and the export resolves. Not persistent — re-runs each boot.
  mkdir -p "${L4T_EXPORT_SRC}"
  sudo mkdir -p "${L4T_EXPORT_DIR}"
  if "${MOUNTPOINT_BIN}" -q "${L4T_EXPORT_DIR}"; then
    _ok "${L4T_EXPORT_DIR} already bind-mounted"
  else
    sudo "${MOUNT_BIN}" --bind "${L4T_EXPORT_SRC}" "${L4T_EXPORT_DIR}"
    _ok "${L4T_EXPORT_DIR} → ${L4T_EXPORT_SRC} (bind)"
  fi

  cat >&2 <<'EOF'

[host-setup] Done. Next:

  ./script/init_data_dirs.sh                            # first run only
  ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml   # pick a preset
  make run -- -t prepare
  # put the Jetson in APX recovery, then:
  ./script/nm_flash_guard.sh auto                       # guard NetworkManager
  make run -- -t flash

Re-run this script after each reboot (settings are not persistent).
EOF
}

main "$@"
