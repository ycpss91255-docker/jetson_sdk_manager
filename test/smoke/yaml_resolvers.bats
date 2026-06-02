#!/usr/bin/env bats
#
# Unit tests for script/lib/yaml.sh::resolve_board_target and
# ::resolve_l4t_release. storage_resolver.bats already covers
# resolve_storage_device; this file locks the other two resolvers'
# error branches — especially the bsp_url / rootfs_url null guard, which
# otherwise lets the literal string "null" reach wget downstream.

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
jetpack_to_l4t:
  "6.2.2":
    l4t_release: R36.5.0
    l4t_archive_tag: r36_release_v5.0
    bsp_url: http://example.invalid/bsp.tbz2
    rootfs_url: http://example.invalid/rootfs.tbz2
  "6.0.0-missing-urls":
    l4t_release: R36.3.0
    l4t_archive_tag: r36_release_v3.0
board_alias_to_target:
  agx-orin: jetson-agx-orin-devkit
EOF
  export L4T_MAPPING_YAML

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/yaml.sh"

  # Merge stderr into stdout so bats `run` sees emit_error's action lines.
  _release() { resolve_l4t_release "$@" 2>&1; }
  _board()   { resolve_board_target "$@" 2>&1; }
}

@test "resolve_l4t_release emits eval-safe KEY=value for a supported version" {
  run resolve_l4t_release 6.2.2
  assert_success
  assert_output --partial 'L4T_RELEASE=R36.5.0'
  assert_output --partial 'BSP_URL=http://example.invalid/bsp.tbz2'
  assert_output --partial 'ROOTFS_URL=http://example.invalid/rootfs.tbz2'
}

@test "resolve_l4t_release rejects an unsupported version listing supported keys" {
  run _release 9.9.9
  assert_failure
  assert_output --partial 'not in'
  assert_output --partial '6.2.2'
}

@test "resolve_l4t_release rejects an entry missing bsp_url / rootfs_url (no literal 'null' to wget)" {
  run _release 6.0.0-missing-urls
  assert_failure
  assert_output --partial 'missing bsp_url / rootfs_url'
  # The release tag exists, so the failure must be the URL guard, not the
  # version-not-found branch.
  refute_output --partial 'not in'
}

@test "resolve_board_target maps a known alias" {
  run resolve_board_target agx-orin
  assert_success
  assert_output 'jetson-agx-orin-devkit'
}

@test "resolve_board_target rejects an unknown alias with action message" {
  run _board orin-quantum
  assert_failure
  assert_output --partial 'not in'
  assert_output --partial 'Use one of:'
}
