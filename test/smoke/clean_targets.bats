#!/usr/bin/env bats
#
# Tests for script/clean.sh dispatch + the phase-marker reset that keeps
# a post-clean re-prepare from silently regenerating nothing. The real rm
# / yq run inside transient containers, so `docker` is stubbed on PATH to
# record its argv (including the embedded -c script) and succeed.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install \
      "${BATS_TEST_DIRNAME}/../../script"; do
    if [[ -f "${candidate}/clean.sh" ]]; then
      CLEAN_SH="${candidate}/clean.sh"
      break
    fi
  done
  if [[ -z "${CLEAN_SH:-}" ]]; then
    skip "clean.sh not present in this image"
  fi

  DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  export DOCKER_LOG

  # Stub docker: `volume inspect` succeeds (named volume exists), every
  # other call records its full argv and exits 0.
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "volume" && "$2" == "inspect" ]]; then
  exit "${STUB_VOLUME_INSPECT_RC:-0}"
fi
printf '=== docker %s\n' "$*" >>"${DOCKER_LOG}"
exit 0
EOF
  chmod +x "${STUB_BIN}/docker"
  export PATH="${STUB_BIN}:${PATH}"

  # purge (#93): a repo skeleton in the tmpdir with a provisioned loop-image
  # store, a cached tarball, and host_teardown.sh stubbed to a logger.
  export L4T_REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
  STORE_DATA="${L4T_REPO_ROOT}/data/jetson_l4t"
  STORE_IMG="${L4T_REPO_ROOT}/data/jetson_l4t.img"
  STORE_MARKER="${L4T_REPO_ROOT}/data/.l4t_store"
  DOWNLOADS="${L4T_REPO_ROOT}/data/downloads"
  mkdir -p "${STORE_DATA}" "${DOWNLOADS}"
  touch "${STORE_DATA}/seed" "${DOWNLOADS}/Jetson_Linux_r36.5.0_aarch64.tbz2"
  : >"${STORE_IMG}"
  export DOWNLOADS_HOST_DIR="${DOWNLOADS}"
  TEARDOWN_LOG="${BATS_TEST_TMPDIR}/teardown.log"; export TEARDOWN_LOG
  HOST_TEARDOWN_BIN="${BATS_TEST_TMPDIR}/host_teardown.sh"
  cat >"${HOST_TEARDOWN_BIN}" <<'EOF'
#!/usr/bin/env bash
printf 'teardown %s\n' "$*" >>"${TEARDOWN_LOG}"
EOF
  chmod +x "${HOST_TEARDOWN_BIN}"
  export HOST_TEARDOWN_BIN
}

# _write_marker <backend> <repo_id> <key=value>
_write_marker() {
  printf 'version=1\nbackend=%s\nrepo_id=%s\n%s\n' "$1" "$2" "$3" >"${STORE_MARKER}"
}

# The repo_id store.sh derives for the tmp repo (sha256 of canonical path).
_own_repo_id() {
  printf '%s' "$(readlink -f "${L4T_REPO_ROOT}")" | sha256sum | cut -c1-16
}

@test "unknown target exits 2 with usage" {
  run "${CLEAN_SH}" frobnicate
  assert_failure 2
  assert_output --partial 'unknown target'
  assert_output --partial 'Usage:'
}

@test "no argument prints usage and exits 0" {
  run "${CLEAN_SH}"
  assert_success
  assert_output --partial 'Usage:'
}

@test "-h prints usage and exits 0" {
  run "${CLEAN_SH}" -h
  assert_success
  assert_output --partial 'Usage:'
}

@test "clean build removes images and resets only the images phase" {
  run "${CLEAN_SH}" build
  assert_success
  run cat "${DOCKER_LOG}"
  assert_output --partial 'alpine:3'         # the rm pass
  assert_output --partial 'mikefarah/yq'     # the marker reset
  assert_output --partial 'drop="images"'    # only images cleared
  refute_output --partial 'drop="rootfs binaries user network images"'
}

@test "clean rootfs resets every phase layered on top of rootfs" {
  run "${CLEAN_SH}" rootfs
  assert_success
  run cat "${DOCKER_LOG}"
  assert_output --partial 'alpine:3'
  assert_output --partial 'drop="rootfs binaries user network images"'
}

@test "clean build falls back to the bind mount when no named volume exists (#31)" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  BINDMOUNT_PATH="${BATS_TEST_TMPDIR}/bind"
  mkdir -p "${BINDMOUNT_PATH}"
  touch "${BINDMOUNT_PATH}/seed"   # non-empty so the fallback engages
  export BINDMOUNT_PATH
  run "${CLEAN_SH}" build
  assert_success
  run cat "${DOCKER_LOG}"
  assert_output --partial "${BINDMOUNT_PATH}:/vol"
}

@test "clean build is idempotent when neither volume nor bind mount exists" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  BINDMOUNT_PATH="${BATS_TEST_TMPDIR}/absent"   # does not exist
  export BINDMOUNT_PATH
  run "${CLEAN_SH}" build
  assert_success
  assert_output --partial 'nothing to do'
}

# ── purge (#93) ──────────────────────────────────────────────────────

@test "clean purge wipes the tree, drops tarballs, tears down, then deletes image + marker" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  _write_marker loop-image "$(_own_repo_id)" "image=${STORE_IMG}"
  run "${CLEAN_SH}" purge
  assert_success
  assert_output --partial "${STORE_IMG}"          # announced before deletion
  run cat "${DOCKER_LOG}"
  assert_output --partial "${STORE_DATA}:/vol"    # the alpine content wipe ran
  run cat "${TEARDOWN_LOG}"
  assert_output 'teardown '
  [[ ! -e "${STORE_IMG}" ]]
  [[ ! -e "${STORE_MARKER}" ]]
  [[ ! -e "${DOWNLOADS}/Jetson_Linux_r36.5.0_aarch64.tbz2" ]]
}

@test "clean purge --keep-downloads leaves the cached tarballs in place" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  _write_marker loop-image "$(_own_repo_id)" "image=${STORE_IMG}"
  run "${CLEAN_SH}" purge --keep-downloads
  assert_success
  [[ ! -e "${STORE_IMG}" ]]
  [[ -e "${DOWNLOADS}/Jetson_Linux_r36.5.0_aarch64.tbz2" ]]
}

@test "clean purge a second time is a successful no-op" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  _write_marker loop-image "$(_own_repo_id)" "image=${STORE_IMG}"
  "${CLEAN_SH}" purge
  rm -rf "${STORE_DATA:?}"/*
  run "${CLEAN_SH}" purge
  assert_success
  assert_output --partial 'nothing to purge'
}

@test "clean purge refuses a marker from another checkout and deletes nothing" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  _write_marker loop-image 0000000000000000 "image=${STORE_IMG}"
  run "${CLEAN_SH}" purge
  assert_failure
  assert_output --partial 'repo_id'
  [[ -e "${STORE_IMG}" ]]
  [[ -e "${STORE_MARKER}" ]]
  [[ ! -s "${TEARDOWN_LOG}" ]]
}

@test "clean purge refuses a malformed marker and deletes nothing" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  printf 'garbage\n' >"${STORE_MARKER}"
  run "${CLEAN_SH}" purge
  assert_failure
  [[ -e "${STORE_IMG}" ]]
  [[ -e "${STORE_MARKER}" ]]
}

@test "clean purge on a directory-bind store removes the (emptied) store dir, never rm -rf" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  local store="${BATS_TEST_TMPDIR}/ext4/store"
  mkdir -p "${store}"
  rm -f "${STORE_IMG}"
  _write_marker directory-bind "$(_own_repo_id)" "store=${store}"
  run "${CLEAN_SH}" purge
  assert_success
  [[ ! -e "${store}" ]]
  [[ ! -e "${STORE_MARKER}" ]]
  run cat "${DOCKER_LOG}"
  refute_output --partial "${store}"      # the container never touched the host store path
}

@test "clean purge on a directory-bind store that is still non-empty after teardown fails loudly" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  local store="${BATS_TEST_TMPDIR}/ext4/store"
  mkdir -p "${store}"; touch "${store}/leftover"
  rm -f "${STORE_IMG}"
  _write_marker directory-bind "$(_own_repo_id)" "store=${store}"
  run "${CLEAN_SH}" purge
  assert_failure
  assert_output --partial 'not empty'
  [[ -e "${store}/leftover" ]]
}

@test "clean purge with no marker still runs all + teardown (native checkout)" {
  STUB_VOLUME_INSPECT_RC=1 export STUB_VOLUME_INSPECT_RC
  rm -f "${STORE_IMG}"
  run "${CLEAN_SH}" purge
  assert_success
  assert_output --partial 'no store marker'
  run cat "${TEARDOWN_LOG}"
  assert_output 'teardown '
}

@test "usage lists purge and --keep-downloads" {
  run "${CLEAN_SH}" -h
  assert_output --partial 'purge'
  assert_output --partial '--keep-downloads'
}
