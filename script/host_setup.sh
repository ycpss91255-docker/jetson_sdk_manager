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
#
# Safe to re-run. The kernel bits need root, so you may be prompted for sudo.
# These settings reset on reboot; re-run after each boot (or persist nfsd via
# `echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf`).
#
# NOTE: the USB autosuspend default only applies to devices that enumerate
# AFTER it is set, so run this before putting the Jetson into recovery. If the
# Jetson is already connected, power-cycle it back into recovery afterwards.

set -euo pipefail

# Overridable for tests; defaults are the real kernel sysfs paths / tools.
USBCORE_PARAMS="${USBCORE_PARAMS:-/sys/module/usbcore/parameters}"
QEMU_IMAGE="${QEMU_IMAGE:-multiarch/qemu-user-static}"
USBFS_MEMORY_MB="${USBFS_MEMORY_MB:-2048}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

_step() { printf '\n\033[36m[host-setup] %s\033[0m\n' "$1" >&2; }
_ok()   { printf '  ok: %s\n' "$1" >&2; }

main() {
  _step "1/4 Registering QEMU binfmt (ARM64 emulation for prepare)"
  if command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    "${DOCKER_BIN}" run --rm --privileged "${QEMU_IMAGE}" --reset -p yes >/dev/null
    _ok "qemu-user-static registered"
  else
    printf '  docker not found on PATH — install Docker, then re-run\n' >&2
  fi

  _step "2/4 Loading nfsd kernel module (NFS export for flash)"
  sudo modprobe nfsd
  _ok "nfsd loaded"

  _step "3/4 Disabling USB autosuspend (prevents mid-flash stalls)"
  echo -1 | sudo tee "${USBCORE_PARAMS}/autosuspend" >/dev/null
  _ok "autosuspend = -1"

  _step "4/4 Raising usbfs buffer to ${USBFS_MEMORY_MB} MB (prevents bulk-write stalls)"
  echo "${USBFS_MEMORY_MB}" | sudo tee "${USBCORE_PARAMS}/usbfs_memory_mb" >/dev/null
  _ok "usbfs_memory_mb = ${USBFS_MEMORY_MB}"

  cat >&2 <<'EOF'

[host-setup] Done. Next:

  ./script/init_data_dirs.sh                            # first run only
  ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml   # pick a preset
  make run -- -t prepare
  # put the Jetson in APX recovery, then:
  make run -- -t flash

Re-run this script after each reboot (settings are not persistent).
EOF
}

main "$@"
