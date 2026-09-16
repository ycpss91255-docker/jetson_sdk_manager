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

# ── marker: validation (the gate in front of every destructive step) ─

# Helper: a repo skeleton with a valid loop-image marker + image file.
_valid_loop_repo() {
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}/data/jetson_l4t"
  IMAGE="${REPO}/data/jetson_l4t.img"
  : >"${IMAGE}"
  MARKER="${REPO}/data/.l4t_store"
  store_marker_write "${MARKER}" backend=loop-image \
    "repo_id=$(store_repo_id "${REPO}")" "image=${IMAGE}"
}

@test "store_marker_validate accepts a well-formed loop-image marker" {
  _valid_loop_repo
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_success
}

@test "store_marker_validate accepts a directory-bind marker pointing at a directory" {
  _valid_loop_repo
  STORE_DIR="${BATS_TEST_TMPDIR}/ext4store"
  mkdir -p "${STORE_DIR}"
  store_marker_write "${MARKER}" backend=directory-bind \
    "repo_id=$(store_repo_id "${REPO}")" "store=${STORE_DIR}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_success
}

@test "store_marker_validate rejects a repo_id from another checkout" {
  _valid_loop_repo
  store_marker_write "${MARKER}" backend=loop-image repo_id=0000000000000000 "image=${IMAGE}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'repo_id'
}

@test "store_marker_validate rejects an unknown backend" {
  _valid_loop_repo
  store_marker_write "${MARKER}" backend=docker-volume \
    "repo_id=$(store_repo_id "${REPO}")" "image=${IMAGE}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'backend'
}

@test "store_marker_validate rejects an unsupported marker version" {
  _valid_loop_repo
  sed -i 's/^version=1$/version=99/' "${MARKER}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'version'
}

@test "store_marker_validate rejects a relative image path" {
  _valid_loop_repo
  store_marker_write "${MARKER}" backend=loop-image \
    "repo_id=$(store_repo_id "${REPO}")" "image=data/jetson_l4t.img"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'absolute'
}

@test "store_marker_validate rejects / and \$HOME as a directory-bind store" {
  _valid_loop_repo
  for bad in / "${HOME}"; do
    store_marker_write "${MARKER}" backend=directory-bind \
      "repo_id=$(store_repo_id "${REPO}")" "store=${bad}"
    run store_marker_validate "${MARKER}" "${REPO}"
    assert_failure
  done
}

@test "store_marker_validate rejects a directory-bind store inside the repo" {
  _valid_loop_repo
  store_marker_write "${MARKER}" backend=directory-bind \
    "repo_id=$(store_repo_id "${REPO}")" "store=${REPO}/data/jetson_l4t"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'inside the repo'
}

@test "store_marker_validate rejects a symlinked image" {
  _valid_loop_repo
  : >"${BATS_TEST_TMPDIR}/real.img"
  rm -f "${IMAGE}"; ln -s "${BATS_TEST_TMPDIR}/real.img" "${IMAGE}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'symlink'
}

@test "store_marker_validate rejects a loop-image marker whose image is not a regular file" {
  _valid_loop_repo
  rm -f "${IMAGE}"; mkdir -p "${IMAGE}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
  assert_output --partial 'regular file'
}

@test "store_marker_validate rejects a missing marker" {
  _valid_loop_repo
  rm -f "${MARKER}"
  run store_marker_validate "${MARKER}" "${REPO}"
  assert_failure
}
