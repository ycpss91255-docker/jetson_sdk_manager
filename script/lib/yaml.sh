#!/usr/bin/env bash
# yaml.sh — read keys from jetson.yaml + _l4t_mapping.yaml via yq.
#
# Wrappers around `yq -r` that fail loudly with `emit_error validate ...`
# instead of bash's silent unbound-var crash. Sourced by prepare.sh /
# flash.sh.

set -euo pipefail

# Caller must have already sourced errors.sh.
if ! declare -F emit_error >/dev/null; then
  printf 'yaml.sh: emit_error not defined — source errors.sh first\n' >&2
  return 1
fi

JETSON_YAML="${JETSON_YAML:-/etc/jetson.yaml}"
L4T_MAPPING_YAML="${L4T_MAPPING_YAML:-/etc/jetson/_l4t_mapping.yaml}"

# yaml_get <file> <yq-expression>
# Echoes the resolved value. Aborts via emit_error if yq evaluates to
# null / empty / missing — the caller wants either a value or a clear
# error, never an empty string silently fed into a downstream command.
yaml_get() {
  local file="$1" expr="$2"
  if [[ ! -f "${file}" ]]; then
    emit_error \
      --category validate \
      --detail "yaml_get: file not found: ${file}" \
      --action "Mount jetson.yaml at ${JETSON_YAML} via setup.conf [volumes]" \
      --action "Run \`./script/setup.sh apply\` to regenerate compose.yaml"
    return 1
  fi
  local val
  val=$(yq -r "${expr}" "${file}")
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    emit_error \
      --category validate \
      --detail "yaml_get: ${expr} missing or null in ${file}" \
      --action "Compare with config/jetson/_example.yaml" \
      --action "Run \`yq '${expr}' ${file}\` to debug"
    return 1
  fi
  printf '%s' "${val}"
}

# yaml_get_optional <file> <yq-expression> [default]
# Returns the default (empty if unset) when yq evaluates to null / empty.
# Use for fields the schema marks OPTIONAL.
yaml_get_optional() {
  local file="$1" expr="$2" default="${3:-}"
  if [[ ! -f "${file}" ]]; then
    printf '%s' "${default}"
    return 0
  fi
  local val
  val=$(yq -r "${expr}" "${file}" 2>/dev/null || true)
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    printf '%s' "${default}"
    return 0
  fi
  printf '%s' "${val}"
}

# resolve_l4t_release <jetpack_version>
# Resolves JetPack version to the L4T metadata bundle (release tag +
# BSP url + rootfs url). Echoes shell `KEY=value` assignments that the
# caller `eval`s.
#
#   eval "$(resolve_l4t_release "$(yaml_get "${JETSON_YAML}" '.jetpack.version')")"
#   echo "${BSP_URL}"
resolve_l4t_release() {
  local jp="$1"
  local release tag bsp rootfs
  release=$(yq -r ".jetpack_to_l4t.\"${jp}\".l4t_release" "${L4T_MAPPING_YAML}")
  tag=$(yq -r ".jetpack_to_l4t.\"${jp}\".l4t_archive_tag" "${L4T_MAPPING_YAML}")
  bsp=$(yq -r ".jetpack_to_l4t.\"${jp}\".bsp_url" "${L4T_MAPPING_YAML}")
  rootfs=$(yq -r ".jetpack_to_l4t.\"${jp}\".rootfs_url" "${L4T_MAPPING_YAML}")
  if [[ -z "${release}" || "${release}" == "null" ]]; then
    emit_error \
      --category validate \
      --detail "JetPack version '${jp}' not in ${L4T_MAPPING_YAML}" \
      --action "Use a supported version: $(yq -r '.jetpack_to_l4t | keys | join(", ")' "${L4T_MAPPING_YAML}")" \
      --action "Or add a new entry — see _l4t_mapping.yaml header for instructions"
    return 1
  fi
  # bsp_url / rootfs_url feed download_if_missing directly. A typo'd or
  # absent key yields the literal string 'null' from yq, which wget then
  # tries to fetch ("wget failed for null") — surface a schema error that
  # names the missing key instead. L4T_ARCHIVE_TAG is not consumed by the
  # download path, so leave it lenient.
  if [[ -z "${bsp}" || "${bsp}" == "null" || -z "${rootfs}" || "${rootfs}" == "null" ]]; then
    emit_error \
      --category validate \
      --detail "JetPack '${jp}' entry in ${L4T_MAPPING_YAML} is missing bsp_url / rootfs_url" \
      --action "Add both bsp_url and rootfs_url under jetpack_to_l4t.\"${jp}\"" \
      --action "Copy the URLs from https://developer.nvidia.com/embedded/jetson-linux-archive"
    return 1
  fi
  printf 'L4T_RELEASE=%q\nL4T_ARCHIVE_TAG=%q\nBSP_URL=%q\nROOTFS_URL=%q\n' \
    "${release}" "${tag}" "${bsp}" "${rootfs}"
}

# resolve_board_target <board_alias>
resolve_board_target() {
  local alias="$1"
  local target
  target=$(yq -r ".board_alias_to_target.\"${alias}\"" "${L4T_MAPPING_YAML}")
  if [[ -z "${target}" || "${target}" == "null" ]]; then
    emit_error \
      --category validate \
      --detail "Board alias '${alias}' not in ${L4T_MAPPING_YAML}" \
      --action "Use one of: $(yq -r '.board_alias_to_target | keys | join(", ")' "${L4T_MAPPING_YAML}")"
    return 1
  fi
  printf '%s' "${target}"
}

# resolve_storage_device <storage_alias> [device_path_override]
#
# Echoes shell `KEY=value` assignments for the caller to `eval`:
#   STORAGE_MODE=internal|external
#   STORAGE_DEVICE=<kernel name>     (empty when mode=internal)
#
# Alias "internal" reserved keyword → mode=internal. Any other mapped
# value is treated as the Jetson-initrd-side kernel device name. The
# optional `device_path_override` (from `storage.device_path` in
# jetson.yaml) replaces the mapped default when mode=external.
#
# Usage:
#   eval "$(resolve_storage_device "${alias}" "${override}")"
#   echo "${STORAGE_MODE} ${STORAGE_DEVICE}"
resolve_storage_device() {
  local alias="$1" override="${2:-}"
  local mapped
  mapped=$(yq -r ".storage_alias_to_device.\"${alias}\"" "${L4T_MAPPING_YAML}")
  if [[ -z "${mapped}" || "${mapped}" == "null" ]]; then
    emit_error \
      --category validate \
      --detail "Storage alias '${alias}' not in ${L4T_MAPPING_YAML}" \
      --action "Use one of: $(yq -r '.storage_alias_to_device | keys | join(", ")' "${L4T_MAPPING_YAML}")"
    return 1
  fi

  if [[ "${mapped}" == "internal" ]]; then
    if [[ -n "${override}" ]]; then
      emit_error \
        --category validate \
        --detail "storage.device_path='${override}' set but storage.device='${alias}' resolves to internal mode" \
        --action "Remove storage.device_path from jetson.yaml" \
        --action "Or change storage.device to an external alias (nvme / usb) if you meant to flash external storage"
      return 1
    fi
    printf 'STORAGE_MODE=internal\nSTORAGE_DEVICE=\n'
    return 0
  fi

  local device="${override:-${mapped}}"
  printf 'STORAGE_MODE=external\nSTORAGE_DEVICE=%q\n' "${device}"
}
