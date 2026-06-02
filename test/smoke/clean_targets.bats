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
