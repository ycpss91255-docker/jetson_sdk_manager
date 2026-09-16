#!/usr/bin/env bats
#
# Unit tests for script/lib/store.sh — the L4T data-store backend vocabulary
# behind host_setup.sh / host_teardown.sh / clean.sh purge (#93): backend
# selection, the versioned ./data/.l4t_store marker, size parsing and the
# device+inode mount-identity check. Pure functions on tmp files; no root.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install/lib \
      /lint/script_lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${candidate}/store.sh" ]]; then
      LIB_DIR="${candidate}"
      break
    fi
  done
  if [[ -z "${LIB_DIR:-}" ]]; then
    skip "script/lib/store.sh not present in this image"
  fi

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/store.sh"
}

# ── backend selection ────────────────────────────────────────────────

@test "store_backend_detect: fuseblk checkout selects loop-image" {
  run store_backend_detect fuseblk
  assert_success
  assert_output 'loop-image'
}

@test "store_backend_detect: ext4 checkout stays native" {
  run store_backend_detect ext4
  assert_success
  assert_output 'native'
}

@test "store_backend_detect: every non-unix fstype selects loop-image" {
  for fs in ntfs ntfs3 exfat vfat msdos; do
    run store_backend_detect "${fs}"
    assert_output 'loop-image'
  done
}

@test "store_backend_detect: L4T_STORE_DIR forces directory-bind even on ext4" {
  L4T_STORE_DIR=/mnt/ext4/store run store_backend_detect ext4
  assert_output 'directory-bind'
}

@test "store_backend_detect: L4T_STORE_BACKEND override wins over fstype" {
  L4T_STORE_BACKEND=loop-image run store_backend_detect ext4
  assert_output 'loop-image'
}

@test "store_backend_detect: unknown L4T_STORE_BACKEND is rejected" {
  L4T_STORE_BACKEND=docker-volume run store_backend_detect ext4
  assert_failure
  assert_output --partial 'unknown backend'
}

# ── marker: write / read ─────────────────────────────────────────────

@test "store_marker_write round-trips every key and pins version=1" {
  local marker="${BATS_TEST_TMPDIR}/data/.l4t_store"
  mkdir -p "${BATS_TEST_TMPDIR}/data"
  run store_marker_write "${marker}" backend=loop-image repo_id=abc123 image=/repo/data/jetson_l4t.img
  assert_success
  run store_marker_read "${marker}" version
  assert_output '1'
  run store_marker_read "${marker}" backend
  assert_output 'loop-image'
  run store_marker_read "${marker}" repo_id
  assert_output 'abc123'
  run store_marker_read "${marker}" image
  assert_output '/repo/data/jetson_l4t.img'
}

@test "store_marker_write leaves no temp file behind (atomic rename)" {
  local marker="${BATS_TEST_TMPDIR}/data/.l4t_store"
  mkdir -p "${BATS_TEST_TMPDIR}/data"
  store_marker_write "${marker}" backend=loop-image repo_id=abc image=/x.img
  run ls -A "${BATS_TEST_TMPDIR}/data"
  assert_output '.l4t_store'
}

@test "store_marker_read of a missing key or file fails" {
  local marker="${BATS_TEST_TMPDIR}/data/.l4t_store"
  mkdir -p "${BATS_TEST_TMPDIR}/data"
  store_marker_write "${marker}" backend=loop-image repo_id=abc image=/x.img
  run store_marker_read "${marker}" store
  assert_failure
  run store_marker_read "${BATS_TEST_TMPDIR}/nope" backend
  assert_failure
}

@test "store_repo_id is stable for the same path and differs across checkouts" {
  mkdir -p "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
  run store_repo_id "${BATS_TEST_TMPDIR}/a"
  assert_success
  local id_a="${output}"
  run store_repo_id "${BATS_TEST_TMPDIR}/a/"        # trailing slash canonicalised
  assert_output "${id_a}"
  run store_repo_id "${BATS_TEST_TMPDIR}/b"
  refute_output "${id_a}"
  [[ "${id_a}" =~ ^[0-9a-f]{16}$ ]]
}
