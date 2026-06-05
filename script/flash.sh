#!/usr/bin/env bash
# flash.sh — Phase 2 of the NVIDIA factory flash workflow.
#
# Reads /etc/jetson.yaml and writes the pre-generated images from the
# jetson_l4t volume to a connected Jetson in APX recovery mode.
# Requires Jetson in recovery before running.
#
# Steps:
#   1. Validate jetson.yaml
#   2. Resolve target + storage device
#   3. Assert volume is prepared (and matches jetson.yaml)
#   4. Probe USB for tegra recovery device
#   5. Check host NFS kernel support (initrd flash serves over NFS)
#   6. l4t_initrd_flash.sh --flash-only
#   7. Print first-boot guidance (apt install nvidia-jetpack)

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/yaml.sh
. "${_HERE}/lib/yaml.sh"
# shellcheck source=lib/volume.sh
. "${_HERE}/lib/volume.sh"
# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"

_step() { printf '\n\033[36m[flash] %s\033[0m\n' "$1" >&2; }

main() {
  _step "1/6 Validating /etc/jetson.yaml"
  local jp board storage_alias storage_device_path hw_target
  jp=$(yaml_get "${JETSON_YAML}" '.jetpack.version')
  board=$(yaml_get "${JETSON_YAML}" '.hardware.board')
  storage_alias=$(yaml_get "${JETSON_YAML}" '.storage.device')
  storage_device_path=$(yaml_get_optional "${JETSON_YAML}" '.storage.device_path' '')

  _step "2/6 Resolving target + storage device"
  hw_target=$(resolve_board_target "${board}")
  # Assign-then-eval so a failed resolve aborts here with its own action
  # message instead of being swallowed by eval and crashing later (set -u).
  local _storage_env
  _storage_env=$(resolve_storage_device "${storage_alias}" "${storage_device_path}") || exit 1
  eval "${_storage_env}"
  printf '  Target:  %s\n  Storage: %s (mode=%s%s)\n' \
    "${hw_target}" "${storage_alias}" "${STORAGE_MODE}" \
    "${STORAGE_DEVICE:+, device=${STORAGE_DEVICE}}" >&2

  _step "3/6 Asserting volume prepared"
  local state
  state=$(volume_state "${jp}" "${hw_target}")
  if [[ "${state}" == "empty" ]]; then
    emit_error \
      --category volume-mismatch \
      --detail "Volume jetson_l4t is empty — no flash images to write" \
      --action "Run \`make run -- -t prepare\` first"
    exit 1
  fi
  volume_assert_match "${jp}" "${hw_target}"
  if ! volume_phase_done "${jp}" "${hw_target}" "images"; then
    emit_error \
      --category volume-mismatch \
      --detail "Volume jetson_l4t has BSP but no flash images" \
      --action "Re-run \`make run -- -t prepare\` to finish image generation"
    exit 1
  fi
  # The volume marker tracks jetpack+board, not storage. Catch a storage-mode
  # change in jetson.yaml since prepare (e.g. emmc→nvme) here — the images on
  # disk are for the recorded mode and flashing them under the other mode's
  # dispatch fails or corrupts the target. Empty recorded mode = legacy marker
  # prepared before this field existed; don't block those.
  local recorded_mode
  recorded_mode=$(volume_storage_mode "${jp}" "${hw_target}")
  if [[ -n "${recorded_mode}" && "${recorded_mode}" != "${STORAGE_MODE}" ]]; then
    emit_error \
      --category volume-mismatch \
      --detail "Volume was prepared for storage mode '${recorded_mode}' but jetson.yaml now resolves to '${STORAGE_MODE}'" \
      --action "internal (emmc) and external (nvme/usb) build different images — flashing across modes will fail or corrupt the target" \
      --action "Rebuild for the new mode: \`make run -- -t prepare\` regenerates the images, then re-run flash" \
      --action "Or revert storage.device in jetson.yaml to the prepared mode (${recorded_mode})"
    exit 1
  fi

  _step "4/6 Probing Jetson USB"
  if ! jetson_in_recovery; then
    emit_error \
      --category hardware \
      --detail "No NVIDIA recovery USB device detected (vendor ${JETSON_USB_VENDOR})" \
      --action "Run \`make run -- -t probe\` to see what is (or is not) on the bus" \
      --action "Power-cycle Jetson into recovery: power off, hold Force-Recovery, tap Reset, release Force-Recovery" \
      --action "Confirm on the host: \`lsusb | grep -i 'NVIDIA Corp'\`" \
      --action "If /dev hotplug is broken in container, restart the container — base v0.39.0 added rslave but old containers stay private"
    exit 1
  fi
  printf '  Recovery device found\n' >&2

  _step "5/6 Checking host NFS kernel support"
  # l4t_initrd_flash boots a minimal initramfs on the Jetson and serves the
  # flash payload to it over NFS (a plain export on the USB/RNDIS link — no
  # iptables / usb-gadget forwarding, unlike SDK Manager). The container has
  # nfs-kernel-server installed, but it shares the host kernel: if the host's
  # nfsd module is not loaded, the server cannot start and the flash dies with
  # an opaque "RPC: Program not registered" / "Return value 114". Catch it here
  # with an actionable message instead. `nfsd` in /proc/filesystems is present
  # iff the module is loaded in the shared kernel. (Path overridable so the
  # smoke test can drive both branches without touching the real /proc.)
  local _proc_fs="${NFS_PROC_FILESYSTEMS:-/proc/filesystems}"
  if ! grep -qw nfsd "${_proc_fs}" 2>/dev/null; then
    emit_error \
      --category host-config \
      --detail "Host kernel nfsd module not loaded — l4t_initrd_flash serves the payload over NFS and cannot start its server without it" \
      --action "On the HOST (not in this container) run: sudo modprobe nfsd" \
      --action "Make it persistent across reboots: echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf" \
      --action "Then re-run: make run -- -t flash"
    exit 1
  fi
  printf '  nfsd kernel support present\n' >&2

  _step "6/6 Flashing (l4t_initrd_flash --flash-only)"
  # HITL-ONLY: CI cannot verify this. l4t_initrd_flash boots a real Jetson
  # initrd and serves the payload to it over NFS on the USB link — it requires
  # physical hardware in recovery, the host nfsd module, and NetworkManager not
  # tearing down the gadget iface (see nm_flash_guard.sh). None of that exists
  # in CI, so the actual write path is only exercised by a hardware flash.
  local l4t_dir
  l4t_dir=$(l4t_root_path "${jp}" "${hw_target}")
  if [[ "${STORAGE_MODE}" == "internal" ]]; then
    (cd "${l4t_dir}" && sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
      --flash-only \
      "${hw_target}" \
      internal)
  else
    (cd "${l4t_dir}" && sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
      --flash-only \
      --external-device "${STORAGE_DEVICE}" \
      "${hw_target}" \
      external)
  fi

  cat <<EOF >&2

[flash] Flash complete. Jetson will reboot into the freshly-flashed OS.

First-boot checklist:
  1. Wait ~2 min for first-boot config to settle.
  2. Reach the Jetson over the USB-C cable — L4T exposes a fixed
     192.168.55.1 (no network config needed): ssh <username>@192.168.55.1
     — or open the desktop session.
  3. Install JetPack SDK components via OTA apt:

       sudo apt update && sudo apt install -y nvidia-jetpack

     (We skip SDK Manager's NFS-based component install because it
     does not work reliably inside Docker — see README.)

EOF
}

main "$@"
