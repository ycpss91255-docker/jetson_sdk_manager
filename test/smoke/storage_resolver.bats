#!/usr/bin/env bats
#
# Unit tests for script/lib/yaml.sh::resolve_storage_device.
#
# Source the lib + a synthetic _l4t_mapping.yaml fixture inside each
# test so the harness exercises the real `yq` lookup that prepare.sh
# and flash.sh hit at runtime. Tests only run inside the prepare /
# flash / devel-test images where the lib is COPY'd; the smoke runner
# already mounts /smoke_test/ so the bats file is discovered, but the
# lib itself is reached via the build-time copy at /opt/jetson_install
# (prepare/flash) or via the lint copy at /lint/script_lib (devel-test).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install/lib \
      /lint/script_lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${candidate}/yaml.sh" ]]; then
      LIB_DIR="${candidate}"
      break
    fi
  done
  if [[ -z "${LIB_DIR:-}" ]]; then
    skip "script/lib not present in this image"
  fi

  command -v yq >/dev/null 2>&1 || skip "yq not on PATH"

  L4T_MAPPING_YAML="${BATS_TEST_TMPDIR}/_l4t_mapping.yaml"
  cat >"${L4T_MAPPING_YAML}" <<'EOF'
storage_alias_to_device:
  emmc: internal
  nvme: nvme0n1p1
  usb: sda1
EOF
  export L4T_MAPPING_YAML

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/yaml.sh"

  # Wrapper that merges stderr into stdout so bats `run` captures both
  # in $output. The `emit_error` failure path writes to stderr; we want
  # to assert on the action message.
  _resolve() {
    resolve_storage_device "$@" 2>&1
  }
}

@test "emmc alias resolves to internal mode with empty device" {
  run resolve_storage_device emmc
  assert_success
  assert_output --partial 'STORAGE_MODE=internal'
  assert_output --partial 'STORAGE_DEVICE='
  refute_output --partial 'STORAGE_DEVICE=mmcblk'
}

@test "nvme alias resolves to external mode with nvme0n1p1" {
  run resolve_storage_device nvme
  assert_success
  assert_output --partial 'STORAGE_MODE=external'
  assert_output --partial 'STORAGE_DEVICE=nvme0n1p1'
}

@test "usb alias resolves to external mode with sda1 default" {
  run resolve_storage_device usb
  assert_success
  assert_output --partial 'STORAGE_MODE=external'
  assert_output --partial 'STORAGE_DEVICE=sda1'
}

@test "device_path override replaces default external device" {
  run resolve_storage_device usb sdb1
  assert_success
  assert_output --partial 'STORAGE_MODE=external'
  assert_output --partial 'STORAGE_DEVICE=sdb1'
}

@test "device_path override on internal alias is rejected" {
  run _resolve emmc sdb1
  assert_failure
  assert_output --partial "internal mode"
}

@test "unknown alias is rejected with action message" {
  run _resolve microsd
  assert_failure
  assert_output --partial "not in"
  assert_output --partial "Use one of:"
}

@test "resolver output is eval-safe" {
  output=$(resolve_storage_device usb 'sd!b1')
  eval "${output}"
  [[ "${STORAGE_MODE}" == "external" ]]
  [[ "${STORAGE_DEVICE}" == 'sd!b1' ]]
}
