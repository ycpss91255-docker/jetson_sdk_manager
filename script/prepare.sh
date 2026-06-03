#!/usr/bin/env bash
# prepare.sh — Phase 1 of the NVIDIA factory flash workflow.
#
# Reads /etc/jetson.yaml (bind-mounted from the repo's jetson.yaml
# symlink) and produces flash images in the jetson_l4t Docker volume.
# Does NOT require a Jetson connected.
#
# Steps (each idempotent; resume mid-pipeline by re-running):
#   1. Validate jetson.yaml schema
#   2. Resolve JetPack version → L4T BSP / rootfs URLs via
#      _l4t_mapping.yaml (build-time COPY'd, not user-editable)
#   3. Check volume state — abort with action message on version
#      mismatch (clean.sh + re-run)
#   4. Download BSP + sample rootfs tarballs (skip if present)
#   5. Extract BSP → ${L4T_ROOT}/Linux_for_Tegra/
#   6. Extract sample rootfs → Linux_for_Tegra/rootfs/
#   7. apply_binaries.sh
#   8. l4t_create_default_user.sh
#   9. (optional) NetworkManager profile from network.method=static
#  10. l4t_initrd_flash.sh --no-flash → tools/kernel_flash/images/
#
# After success: print "run \`make run -- -t flash\` next".

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/yaml.sh
. "${_HERE}/lib/yaml.sh"
# shellcheck source=lib/download.sh
. "${_HERE}/lib/download.sh"
# shellcheck source=lib/volume.sh
. "${_HERE}/lib/volume.sh"

_step() { printf '\n\033[36m[prepare] %s\033[0m\n' "$1" >&2; }

# L4T_ROOT lives on the host's data/jetson_l4t/ via setup.conf. NVIDIA's
# apply_binaries.sh creates a setuid `sudo` and root-owned files inside
# rootfs/; NTFS / exFAT / fuseblk filesystems silently drop both, which
# yields a broken flashed Jetson (sudo refuses to start). Abort early.
_assert_unix_fs() {
  local path="$1"
  mkdir -p "${path}"
  local fstype
  fstype=$(stat -f -c %T "${path}" 2>/dev/null || true)
  case "${fstype}" in
    ext2/ext3|ext4|xfs|btrfs|zfs|tmpfs|overlayfs)
      return 0
      ;;
    fuseblk|ntfs*|exfat|vfat|msdos)
      if [[ "${JETSON_ALLOW_NON_UNIX_FS:-0}" == "1" ]]; then
        printf '[prepare] WARNING: L4T_ROOT is on %s and JETSON_ALLOW_NON_UNIX_FS=1 — continuing anyway. The flashed Jetson may end up with a broken sudo if setuid/ownership got stripped during apply_binaries.sh.\n' \
          "${fstype}" >&2
        return 0
      fi
      emit_error \
        --category permission \
        --detail "L4T_ROOT (${path}) is on ${fstype} — cannot preserve setuid / root ownership" \
        --action "Move this repo to an ext4 / xfs / btrfs partition" \
        --action "Or bind-mount an ext4 dir over ./data/jetson_l4t/: \`sudo mkdir -p /var/lib/jetson_l4t && sudo mount --bind /var/lib/jetson_l4t ./data/jetson_l4t\`" \
        --action "Or opt in to the unsafe path: \`JETSON_ALLOW_NON_UNIX_FS=1 make run -- -t prepare\`"
      return 1
      ;;
    *)
      printf '[prepare] Unknown filesystem type %s — proceeding (verify setuid preservation manually)\n' "${fstype}" >&2
      return 0
      ;;
  esac
}

# NVIDIA's on-device flash agent formats the APP (rootfs) partition with
# `mkfs.ext4 -F`, whose default block discard (TRIM) on a large eMMC can take
# minutes with no USB traffic. During that idle window the flash-stage USB link
# can drop, killing the rootfs write — the flash dies at "Discarding device
# blocks" with a misleading "cannot mount NFS server" / Return value 114.
# `-E nodiscard` makes the format instant and removes that window.
#
# Patch the generated, device-served copy (l4t_initrd_flash copies images/
# l4t_flash_from_kernel.sh to the target at flash time). Idempotent, and a
# no-op if a future BSP changes the mkfs line (the match point is gone).
_patch_skip_emmc_discard() {
  local kf="$1/tools/kernel_flash/images/l4t_flash_from_kernel.sh"
  [[ -f "${kf}" ]] || return 0
  if grep -Fq 'nodiscard' "${kf}" 2>/dev/null; then
    return 0
  fi
  if ! grep -Fq '"${tool}" -F "${APP_partition}"' "${kf}" 2>/dev/null; then
    printf '  (eMMC skip-discard patch point not found — BSP flash script changed; left as-is)\n' >&2
    return 0
  fi
  # File is generated under sudo and may be root-owned.
  sudo sed -i 's@"${tool}" -F "${APP_partition}"@"${tool}" -F -E nodiscard "${APP_partition}"@' "${kf}"
  printf '  Patched APP-partition format to skip eMMC discard (prevents USB-link drop mid-flash)\n' >&2
}

main() {
  _step "0/10 Verifying L4T_ROOT filesystem is unix-compatible"
  _assert_unix_fs "${L4T_ROOT}"

  _step "1/10 Validating /etc/jetson.yaml"
  local jp board storage_alias storage_device_path hw_target username password hostname autologin
  jp=$(yaml_get "${JETSON_YAML}" '.jetpack.version')
  board=$(yaml_get "${JETSON_YAML}" '.hardware.board')
  storage_alias=$(yaml_get "${JETSON_YAML}" '.storage.device')
  storage_device_path=$(yaml_get_optional "${JETSON_YAML}" '.storage.device_path' '')
  username=$(yaml_get "${JETSON_YAML}" '.user.username')
  password=$(yaml_get "${JETSON_YAML}" '.user.password')
  hostname=$(yaml_get "${JETSON_YAML}" '.user.hostname')
  autologin=$(yaml_get_optional "${JETSON_YAML}" '.user.autologin' 'false')

  _step "2/10 Resolving JetPack ${jp} → L4T metadata"
  # Assign-then-eval: `eval "$(resolver)"` swallows the resolver's non-zero
  # exit (eval of empty output succeeds), so a validation failure would
  # slip through and only crash later via set -u with noisy output. Capture
  # first so a failed resolve aborts here with its own action message.
  local _release_env _storage_env
  _release_env=$(resolve_l4t_release "${jp}") || exit 1
  eval "${_release_env}"
  hw_target=$(resolve_board_target "${board}")
  _storage_env=$(resolve_storage_device "${storage_alias}" "${storage_device_path}") || exit 1
  eval "${_storage_env}"
  printf '  L4T release: %s\n  Target:      %s\n  Storage:     %s (mode=%s%s)\n' \
    "${L4T_RELEASE}" "${hw_target}" "${storage_alias}" "${STORAGE_MODE}" \
    "${STORAGE_DEVICE:+, device=${STORAGE_DEVICE}}" >&2

  _step "3/10 Probing volume state"
  volume_assert_match "${jp}" "${hw_target}"
  local l4t_dir
  l4t_dir=$(l4t_root_path "${jp}" "${hw_target}")
  mkdir -p "${l4t_dir}"
  # Stamp an empty marker before the first extraction so a crash mid-phase
  # leaves a matching ledger behind — the next run resumes instead of
  # treating the half-extracted tree as a forced-clean mismatch.
  volume_init_marker "${jp}" "${hw_target}"
  # internal (emmc) and external (nvme/usb) produce different flash images.
  # If the prepared mode differs from what jetson.yaml now resolves to, drop
  # the images phase so step 10 regenerates them for the new mode (the rootfs
  # tree itself is mode-independent), then record the new mode. Without this,
  # re-prepare would skip image generation and flash would write wrong-mode
  # images.
  local _recorded_mode
  _recorded_mode=$(volume_storage_mode "${jp}" "${hw_target}")
  if [[ -n "${_recorded_mode}" && "${_recorded_mode}" != "${STORAGE_MODE}" ]]; then
    printf '  Storage mode changed (%s → %s) — flash images will be regenerated\n' \
      "${_recorded_mode}" "${STORAGE_MODE}" >&2
    volume_drop_phase "${jp}" "${hw_target}" "images"
  fi
  volume_record_storage_mode "${jp}" "${hw_target}" "${STORAGE_MODE}"

  _step "4/10 Downloading BSP + rootfs tarballs (skip if cached)"
  local bsp_tar rootfs_tar
  bsp_tar=$(download_if_missing "${BSP_URL}")
  rootfs_tar=$(download_if_missing "${ROOTFS_URL}")

  _step "5/10 Extracting BSP"
  if ! volume_phase_done "${jp}" "${hw_target}" "bsp"; then
    tar -I lbzip2 -xpf "${bsp_tar}" -C "${l4t_dir}/.." \
      || tar -xjpf "${bsp_tar}" -C "${l4t_dir}/.."
    volume_record_phase "${jp}" "${hw_target}" "bsp"
  else
    printf '  BSP already extracted — skipping\n' >&2
  fi

  _step "6/10 Extracting sample rootfs"
  if ! volume_phase_done "${jp}" "${hw_target}" "rootfs"; then
    mkdir -p "${l4t_dir}/rootfs"
    if ! sudo tar -I lbzip2 -xpf "${rootfs_tar}" -C "${l4t_dir}/rootfs"; then
      sudo tar -xjpf "${rootfs_tar}" -C "${l4t_dir}/rootfs"
    fi
    volume_record_phase "${jp}" "${hw_target}" "rootfs"
  else
    printf '  Rootfs already extracted — skipping\n' >&2
  fi

  _step "7/10 Applying binaries (apply_binaries.sh)"
  if ! volume_phase_done "${jp}" "${hw_target}" "binaries"; then
    (cd "${l4t_dir}" && sudo ./apply_binaries.sh)
    volume_record_phase "${jp}" "${hw_target}" "binaries"
  else
    printf '  apply_binaries.sh already run — skipping\n' >&2
  fi

  _step "8/10 Pre-creating default user (skip OEM-config)"
  if ! volume_phase_done "${jp}" "${hw_target}" "user"; then
    local auto_flag=""
    [[ "${autologin}" == "true" ]] && auto_flag="--autologin"
    (cd "${l4t_dir}" && sudo ./tools/l4t_create_default_user.sh \
      --accept-license \
      -u "${username}" \
      -p "${password}" \
      -n "${hostname}" \
      ${auto_flag})
    volume_record_phase "${jp}" "${hw_target}" "user"
  else
    printf '  Default user already configured — skipping\n' >&2
  fi

  _step "9/10 Configuring network"
  local netmethod
  netmethod=$(yaml_get_optional "${JETSON_YAML}" '.network.method' '')
  if [[ "${netmethod}" != "static" ]]; then
    printf '  DHCP (default) — no profile written\n' >&2
  elif volume_phase_done "${jp}" "${hw_target}" "network"; then
    printf '  Static profile already installed — skipping\n' >&2
  else
    local addr gateway dns_list
    addr=$(yaml_get "${JETSON_YAML}" '.network.static.address')
    gateway=$(yaml_get "${JETSON_YAML}" '.network.static.gateway')
    dns_list=$(yaml_get "${JETSON_YAML}" '.network.static.dns | join(";")')
    sudo mkdir -p "${l4t_dir}/rootfs/etc/NetworkManager/system-connections"
    printf '%s\n' \
      '[connection]' \
      'id=jetson-static' \
      'type=ethernet' \
      'autoconnect=true' \
      '' \
      '[ipv4]' \
      "addresses=${addr}" \
      "gateway=${gateway}" \
      "dns=${dns_list};" \
      'method=manual' \
      | sudo tee "${l4t_dir}/rootfs/etc/NetworkManager/system-connections/jetson-static.nmconnection" >/dev/null
    sudo chmod 600 "${l4t_dir}/rootfs/etc/NetworkManager/system-connections/jetson-static.nmconnection"
    volume_record_phase "${jp}" "${hw_target}" "network"
    printf '  Static profile installed: %s via %s\n' "${addr}" "${gateway}" >&2
  fi

  _step "10/10 Generating flash images (l4t_initrd_flash --no-flash)"
  if ! volume_phase_done "${jp}" "${hw_target}" "images"; then
    if [[ "${STORAGE_MODE}" == "internal" ]]; then
      (cd "${l4t_dir}" && sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
        --no-flash \
        "${hw_target}" \
        internal)
    else
      (cd "${l4t_dir}" && sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
        --no-flash \
        --external-device "${STORAGE_DEVICE}" \
        --external-only \
        -c ./tools/kernel_flash/flash_l4t_external.xml \
        -p '-c bootloader/generic/cfg/flash_t234_qspi.xml' \
        --network usb0 \
        "${hw_target}" \
        external)
    fi
    volume_record_phase "${jp}" "${hw_target}" "images"
  else
    printf '  Flash images already generated — skipping\n' >&2
  fi

  _patch_skip_emmc_discard "${l4t_dir}"

  cat <<EOF >&2

[prepare] Phase 1 complete. Volume jetson_l4t is ready.

Next step:
  1. Put Jetson into APX recovery: power off, hold Force-Recovery, reconnect power, release Force-Recovery.
  2. Confirm the link: make run -- -t probe   (exits 0 when a Jetson is in APX)
  3. Run: make run -- -t flash

EOF
}

main "$@"
