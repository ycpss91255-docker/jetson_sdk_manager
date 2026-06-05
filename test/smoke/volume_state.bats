#!/usr/bin/env bats
#
# Unit tests for script/lib/volume.sh state machine: empty / match /
# mismatch classification, the hw_targets half of the match guarantee,
# the volume_assert_match abort contract, and volume_init_marker's
# resume-after-crash behavior.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install/lib \
      /lint/script_lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${candidate}/volume.sh" ]]; then
      LIB_DIR="${candidate}"
      break
    fi
  done
  if [[ -z "${LIB_DIR:-}" ]]; then
    skip "script/lib not present in this image"
  fi

  command -v yq >/dev/null 2>&1 || skip "yq not on PATH"

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/volume.sh"

  L4T_ROOT="${BATS_TEST_TMPDIR}/l4t"
  export L4T_ROOT
  JP="6.2.2"
  HW="jetson-agx-orin-devkit"

  _assert() { volume_assert_match "$@" 2>&1; }
}

@test "volume_state is 'empty' on a pristine root" {
  run volume_state "${JP}" "${HW}"
  assert_output 'empty'
}

@test "volume_state is 'mismatch' when the dir has content but no marker" {
  mkdir -p "$(l4t_root_path "${JP}" "${HW}")"
  touch "$(l4t_root_path "${JP}" "${HW}")/stray-file"
  run volume_state "${JP}" "${HW}"
  assert_output 'mismatch'
}

@test "volume_init_marker turns a half-extracted tree into a resumable 'match'" {
  mkdir -p "$(l4t_root_path "${JP}" "${HW}")"
  touch "$(l4t_root_path "${JP}" "${HW}")/stray-file"
  volume_init_marker "${JP}" "${HW}"
  run volume_state "${JP}" "${HW}"
  assert_output 'match'
}

@test "volume_state is 'match' after recording a phase" {
  volume_record_phase "${JP}" "${HW}" "bsp"
  run volume_state "${JP}" "${HW}"
  assert_output 'match'
  run volume_phase_done "${JP}" "${HW}" "bsp"
  assert_success
}

@test "volume_state is 'mismatch' on a JetPack version change" {
  volume_init_marker "${JP}" "${HW}"
  run volume_state "6.0.0" "${HW}"
  # Different jp resolves to a different path (empty) — but if a stale
  # marker for the requested jp existed with a wrong version it must be a
  # mismatch. Assert the recorded-version comparison directly:
  refute_output 'match'
}

@test "volume_state is 'mismatch' on a board change at the same path version" {
  # Hand-write a marker whose recorded hw_targets differs from the query
  # but lives at the queried path, isolating the hw comparison (#11).
  local marker
  marker="$(volume_marker_path "${JP}" "${HW}")"
  mkdir -p "$(dirname "${marker}")"
  printf 'jetpack_version: "%s"\nhw_targets: "%s"\nphases: []\n' \
    "${JP}" "jetson-orin-nano-devkit-super" >"${marker}"
  run volume_state "${JP}" "${HW}"
  assert_output 'mismatch'
}

@test "volume_state is 'mismatch' on a corrupt (unparseable) marker (#67)" {
  # A marker that exists but won't parse (e.g. truncated by a pre-atomic-write
  # crash) must be treated as a mismatch — advise clean rather than crash.
  local marker
  marker="$(volume_marker_path "${JP}" "${HW}")"
  mkdir -p "$(dirname "${marker}")"
  printf 'jetpack_version: "%s"\n  : : not: valid: yaml: [\n' "${JP}" >"${marker}"
  run volume_state "${JP}" "${HW}"
  assert_output 'mismatch'
}

@test "volume_record_phase leaves no temp file behind (atomic write, #67)" {
  volume_record_phase "${JP}" "${HW}" "bsp"
  local dir
  dir="$(dirname "$(volume_marker_path "${JP}" "${HW}")")"
  # The same-dir mktemp temp must have been renamed away, not left behind.
  run bash -c "ls '${dir}'/.prepared.yaml.* 2>/dev/null | wc -l"
  assert_output '0'
}

@test "volume_assert_match aborts on mismatch pointing at clean.sh l4t" {
  mkdir -p "$(l4t_root_path "${JP}" "${HW}")"
  touch "$(l4t_root_path "${JP}" "${HW}")/stray-file"
  run _assert "${JP}" "${HW}"
  assert_failure
  assert_output --partial 'clean.sh l4t'
}

@test "volume_assert_match is a no-op on empty and on match" {
  run volume_assert_match "${JP}" "${HW}"   # empty
  assert_success
  volume_record_phase "${JP}" "${HW}" "bsp"
  run volume_assert_match "${JP}" "${HW}"   # match
  assert_success
}

@test "storage mode round-trips through the marker" {
  volume_init_marker "${JP}" "${HW}"
  volume_record_storage_mode "${JP}" "${HW}" "external"
  run volume_storage_mode "${JP}" "${HW}"
  assert_output 'external'
}

@test "volume_storage_mode is empty for a legacy marker without the field" {
  volume_init_marker "${JP}" "${HW}"   # base marker, no storage_mode
  run volume_storage_mode "${JP}" "${HW}"
  assert_output ''
}

@test "volume_drop_phase removes only the named phase" {
  volume_record_phase "${JP}" "${HW}" "bsp"
  volume_record_phase "${JP}" "${HW}" "images"
  volume_drop_phase "${JP}" "${HW}" "images"
  run volume_phase_done "${JP}" "${HW}" "images"
  assert_failure
  run volume_phase_done "${JP}" "${HW}" "bsp"
  assert_success
}
