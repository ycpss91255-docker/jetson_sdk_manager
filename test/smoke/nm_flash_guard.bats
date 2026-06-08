#!/usr/bin/env bats
#
# Unit tests for script/nm_flash_guard.sh auto mode (#50). NetworkManager
# is not active inside the CI container, so disable/enable degrade to
# no-ops (no sudo, no nmcli) and we can exercise the watcher's control
# flow — boot-detected vs timed-out — by stubbing lsusb.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for cand in \
      /opt/jetson_install/nm_flash_guard.sh \
      "${BATS_TEST_DIRNAME}/../../script/nm_flash_guard.sh"; do
    if [[ -x "${cand}" ]]; then
      GUARD_SH="${cand}"
      break
    fi
  done
  [[ -n "${GUARD_SH:-}" ]] || skip "script/nm_flash_guard.sh not present in this image"

  # Isolate all host-touching state to the test tmpdir.
  export NM_GUARD_CONF="${BATS_TEST_TMPDIR}/guard.conf"
  export NM_GUARD_PIDFILE="${BATS_TEST_TMPDIR}/watch.pid"
  export NM_GUARD_POLL_INTERVAL=1
}

_stub_lsusb() {
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  printf '%s\n' '#!/usr/bin/env bash' "$1" >"${STUB_BIN}/lsusb"
  chmod +x "${STUB_BIN}/lsusb"
  export PATH="${STUB_BIN}:${PATH}"
}

# Stub sudo (strip leading flags, exec the rest), visudo (configurable exit),
# and install (copy ignoring -o/-g so it works unprivileged). Used by the
# autohook tests (#80).
_stub_autohook_bins() {
  local visudo_exit="${1:-0}"
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  printf '%s\n' '#!/usr/bin/env bash' 'while [[ "$1" == -* ]]; do shift; done' 'exec "$@"' \
    >"${STUB_BIN}/sudo"
  printf '%s\n' '#!/usr/bin/env bash' "exit ${visudo_exit}" >"${STUB_BIN}/visudo"
  cat >"${STUB_BIN}/install" <<'EOF'
#!/usr/bin/env bash
mode=""; src=""; dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) mode="$2"; shift 2 ;;
    -o|-g) shift 2 ;;
    *) if [[ -z "$src" ]]; then src="$1"; else dest="$1"; fi; shift ;;
  esac
done
cp "$src" "$dest"; [[ -n "$mode" ]] && chmod "$mode" "$dest"; exit 0
EOF
  chmod +x "${STUB_BIN}/sudo" "${STUB_BIN}/visudo" "${STUB_BIN}/install"
  export PATH="${STUB_BIN}:${PATH}"
  export NM_GUARD_AUTOHOOK="${BATS_TEST_TMPDIR}/hook.sh"
  export NM_GUARD_SUDOERS="${BATS_TEST_TMPDIR}/sudoers"
  export NM_GUARD_USER="tester"
}

@test "unknown subcommand exits 2 and the usage lists auto" {
  run bash -c "'${GUARD_SH}' bogus 2>&1"
  assert_failure
  assert_output --partial 'auto'
}

@test "status reports ENABLED when no guard file is present" {
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'ENABLED (normal mode)'
}

@test "_watch re-enables immediately once the booted PID appears" {
  _stub_lsusb "printf 'Bus 001 Device 003: ID 0955:7020 NVIDIA Corp. L4T\n'"
  run bash -c "'${GUARD_SH}' _watch 30 2>&1"
  assert_success
  assert_output --partial 'Jetson booted'
}

@test "_watch times out and restores NetworkManager on an empty bus" {
  _stub_lsusb "exit 0"
  run bash -c "'${GUARD_SH}' _watch 1 2>&1"
  assert_success
  assert_output --partial 'timed out'
}

@test "status surfaces a failed auto re-enable from the marker (#77)" {
  printf 'could not re-enable NetworkManager. Run: nm_flash_guard.sh enable\n' \
    > "${NM_GUARD_PIDFILE}.failed"
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'could not re-enable'
}

@test "_watch leaves a .failed marker when it cannot re-enable (#77)" {
  # Guard file present + a sudo stub that reports success but removes nothing,
  # so enable() finds the guard still there and reports failure.
  printf '[keyfile]\nunmanaged-devices=driver:rndis_host\n' > "${NM_GUARD_CONF}"
  local stub2="${BATS_TEST_TMPDIR}/stub2"
  mkdir -p "${stub2}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${stub2}/sudo"
  chmod +x "${stub2}/sudo"
  _stub_lsusb "printf 'Bus 001 Device 003: ID 0955:7020 NVIDIA Corp. L4T\n'"
  PATH="${stub2}:${PATH}" run bash -c "'${GUARD_SH}' _watch 30 2>&1"
  assert_success
  [[ -e "${NM_GUARD_PIDFILE}.failed" ]]
}

@test "usage lists the new watch + autohook subcommands (#80)" {
  run bash -c "'${GUARD_SH}' bogus 2>&1"
  assert_failure
  assert_output --partial 'watch'
  assert_output --partial 'install-autohook'
}

@test "enable uses the autohook when installed (#80)" {
  # Guard present; an installed autohook that removes the guard. enable() should
  # take the autohook path (no interactive sudo) and report it.
  printf '[keyfile]\n' > "${NM_GUARD_CONF}"
  _stub_autohook_bins 0
  printf '%s\n' '#!/usr/bin/env bash' 'rm -f "${NM_GUARD_CONF}"' > "${NM_GUARD_AUTOHOOK}"
  chmod +x "${NM_GUARD_AUTOHOOK}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial 'via autohook'
  [[ ! -e "${NM_GUARD_CONF}" ]]
}

@test "status reports whether the autohook is installed (#80)" {
  _stub_autohook_bins 0
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'autohook: not installed'

  printf '%s\n' '#!/usr/bin/env bash' 'true' > "${NM_GUARD_AUTOHOOK}"
  chmod +x "${NM_GUARD_AUTOHOOK}"
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'autohook: installed'
}

@test "install-autohook writes a narrow helper + sudoers entry (#80)" {
  _stub_autohook_bins 0
  run bash -c "'${GUARD_SH}' install-autohook 2>&1"
  assert_success
  [[ -x "${NM_GUARD_AUTOHOOK}" ]]
  run cat "${NM_GUARD_SUDOERS}"
  assert_output --partial 'NOPASSWD'
  assert_output --partial "${NM_GUARD_AUTOHOOK}"
  run cat "${NM_GUARD_AUTOHOOK}"
  assert_output --partial "${NM_GUARD_CONF}"   # helper removes the known guard file
}

@test "install-autohook aborts (no files) when the sudoers entry fails validation (#80)" {
  _stub_autohook_bins 1   # visudo -c returns non-zero
  run bash -c "'${GUARD_SH}' install-autohook 2>&1"
  assert_failure
  assert_output --partial 'failed validation'
  [[ ! -e "${NM_GUARD_SUDOERS}" ]]
  [[ ! -e "${NM_GUARD_AUTOHOOK}" ]]
}
