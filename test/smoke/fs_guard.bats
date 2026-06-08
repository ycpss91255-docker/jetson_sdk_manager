#!/usr/bin/env bats
#
# Unit tests for script/lib/fs.sh (assert_unix_fs) and the SDK Manager
# launcher script/sdkm-entrypoint.sh (#51). The filesystem type is forced
# by stubbing `stat`, so these run host-independently.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for cand in \
      /opt/jetson_install/lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${cand}/fs.sh" ]]; then
      LIB_DIR="${cand}"
      break
    fi
  done
  [[ -n "${LIB_DIR:-}" ]] || skip "script/lib/fs.sh not present in this image"

  for cand in \
      /opt/jetson_install/sdkm-entrypoint.sh \
      "${BATS_TEST_DIRNAME}/../../script/sdkm-entrypoint.sh"; do
    if [[ -x "${cand}" ]]; then
      SDKM_SH="${cand}"
      break
    fi
  done

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/fs.sh"
}

_stub_stat() {
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$1'" >"${STUB_BIN}/stat"
  chmod +x "${STUB_BIN}/stat"
  export PATH="${STUB_BIN}:${PATH}"
}

@test "assert_unix_fs accepts a unix filesystem" {
  _stub_stat ext4
  run assert_unix_fs "${BATS_TEST_TMPDIR}/d" prepare
  assert_success
}

@test "assert_unix_fs aborts on ntfs and names the broken-sudo risk" {
  _stub_stat ntfs
  run assert_unix_fs "${BATS_TEST_TMPDIR}/d" prepare
  assert_failure
  assert_output --partial 'broken sudo'
}

@test "assert_unix_fs honours JETSON_ALLOW_NON_UNIX_FS opt-in" {
  _stub_stat ntfs
  JETSON_ALLOW_NON_UNIX_FS=1 run assert_unix_fs "${BATS_TEST_TMPDIR}/d" sdkmanager
  assert_success
  assert_output --partial 'WARNING'
}

@test "assert_unix_fs proceeds (with a note) on an unknown filesystem" {
  _stub_stat someweirdfs
  run assert_unix_fs "${BATS_TEST_TMPDIR}/d" prepare
  assert_success
  assert_output --partial 'Unknown filesystem'
}

@test "assert_unix_fs also catches exfat and forwards a caller --action" {
  _stub_stat exfat
  run assert_unix_fs "${BATS_TEST_TMPDIR}/d" sdkmanager --action "host: ./data/nvidia_sdk"
  assert_failure
  assert_output --partial 'exfat'
  assert_output --partial './data/nvidia_sdk'   # caller-forwarded --action shows up
}

@test "sdkm-entrypoint exits 2 when no SDK Manager command is given" {
  [[ -n "${SDKM_SH:-}" ]] || skip "sdkm-entrypoint.sh not present in this image"
  SDKM_DATA_DIR="${BATS_TEST_TMPDIR}/sdk" SDKM_CONF_DIR="${BATS_TEST_TMPDIR}/conf" \
    run "${SDKM_SH}"
  assert_failure
  [[ "${status}" -eq 2 ]]
}

@test "sdkm-entrypoint execs the given command on a unix filesystem" {
  [[ -n "${SDKM_SH:-}" ]] || skip "sdkm-entrypoint.sh not present in this image"
  SDKM_DATA_DIR="${BATS_TEST_TMPDIR}/sdk" SDKM_CONF_DIR="${BATS_TEST_TMPDIR}/conf" \
    run "${SDKM_SH}" echo sdkm-ran
  assert_success
  assert_output --partial 'sdkm-ran'
}

@test "sdkm-entrypoint aborts when ~/.nvsdkm is on a non-unix FS (#85)" {
  [[ -n "${SDKM_SH:-}" ]] || skip "sdkm-entrypoint.sh not present in this image"
  # stat stub: nvidia_sdk dir passes (ext4), the nvsdkm/conf dir is ntfs — so
  # the data-dir guard clears and the new nvsdkm guard is the one that fires.
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do p="$a"; done
case "$p" in
  *conf*|*nvsdkm*) printf 'ntfs\n' ;;
  *) printf 'ext4\n' ;;
esac
EOF
  chmod +x "${STUB_BIN}/stat"
  SDKM_DATA_DIR="${BATS_TEST_TMPDIR}/nvidia_sdk" SDKM_CONF_DIR="${BATS_TEST_TMPDIR}/conf" \
    PATH="${STUB_BIN}:${PATH}" run "${SDKM_SH}" echo should-not-run
  assert_failure
  refute_output --partial 'should-not-run'
  assert_output --partial './data/nvsdkm'   # the nvsdkm guard's --action, not the data-dir one
}
