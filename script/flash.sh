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
#   5. l4t_initrd_flash.sh --flash-only
#   6. Print first-boot guidance (apt install nvidia-jetpack)

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/yaml.sh
. "${_HERE}/lib/yaml.sh"
# shellcheck source=lib/volume.sh
. "${_HERE}/lib/volume.sh"

_step() { printf '\n\033[36m[flash] %s\033[0m\n' "$1" >&2; }

# Tegra recovery USB vendor:product IDs. ECID-specific match is done by
# tegrarcm_v2 once we know one is present; this initial probe just
# confirms *some* NVIDIA recovery device is on the bus.
_TEGRA_USB_VENDOR='0955'  # NVIDIA Corp
# Known recovery PIDs across Orin family. Not exhaustive — new SKUs may
# need to be added. Source: /usr/share/sdkmanager/Assets/Manifest.json.
_TEGRA_USB_PIDS=('7023' '7223' '7423' '7523' '7e19')

_usb_jetson_present() {
  local pid
  for pid in "${_TEGRA_USB_PIDS[@]}"; do
    if lsusb -d "${_TEGRA_USB_VENDOR}:${pid}" 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

main() {
  _step "1/5 Validating /etc/jetson.yaml"
  local jp board storage_alias storage_device_path hw_target
  jp=$(yaml_get "${JETSON_YAML}" '.jetpack.version')
  board=$(yaml_get "${JETSON_YAML}" '.hardware.board')
  storage_alias=$(yaml_get "${JETSON_YAML}" '.storage.device')
  storage_device_path=$(yaml_get_optional "${JETSON_YAML}" '.storage.device_path' '')

  _step "2/5 Resolving target + storage device"
  hw_target=$(resolve_board_target "${board}")
  eval "$(resolve_storage_device "${storage_alias}" "${storage_device_path}")"
  printf '  Target:  %s\n  Storage: %s (mode=%s%s)\n' \
    "${hw_target}" "${storage_alias}" "${STORAGE_MODE}" \
    "${STORAGE_DEVICE:+, device=${STORAGE_DEVICE}}" >&2

  _step "3/5 Asserting volume prepared"
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

  _step "4/5 Probing Jetson USB"
  if ! _usb_jetson_present; then
    emit_error \
      --category hardware \
      --detail "No NVIDIA recovery USB device detected (vendor ${_TEGRA_USB_VENDOR})" \
      --action "Power-cycle Jetson into recovery: power off, hold Force-Recovery, tap Reset, release Force-Recovery" \
      --action "Confirm on the host: \`lsusb | grep -i 'NVIDIA Corp'\`" \
      --action "If /dev hotplug is broken in container, restart the container — base v0.39.0 added rslave but old containers stay private"
    exit 1
  fi
  printf '  Recovery device found\n' >&2

  _step "5/5 Flashing (l4t_initrd_flash --flash-only)"
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
  2. SSH or open the desktop session.
  3. Install JetPack SDK components via OTA apt:

       sudo apt update && sudo apt install -y nvidia-jetpack

     (We skip SDK Manager's NFS-based component install because it
     does not work reliably inside Docker — see README.)

EOF
}

main "$@"
