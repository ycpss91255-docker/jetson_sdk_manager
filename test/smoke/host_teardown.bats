#!/usr/bin/env bats
#
# Tests for script/host_teardown.sh — reverses host_setup.sh's host mutations.
# sudo / umount / mountpoint and nm_flash_guard.sh are stubbed on PATH and the
# usbcore sysfs path is redirected to a tmp dir so the script runs without root
# or real hardware.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install \
      "${BATS_TEST_DIRNAME}/../../script"; do
    if [[ -f "${candidate}/host_teardown.sh" ]]; then
      HOST_TEARDOWN="${candidate}/host_teardown.sh"
      break
    fi
  done
  if [[ -z "${HOST_TEARDOWN:-}" ]]; then
    skip "host_teardown.sh not present in this image"
  fi

  UMOUNT_LOG="${BATS_TEST_TMPDIR}/umount.log"
  export UMOUNT_LOG
  NM_GUARD_LOG="${BATS_TEST_TMPDIR}/nm_guard.log"
  export NM_GUARD_LOG

  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  # sudo: strip leading flags, then exec the rest (pass-through).
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do shift; done
exec "$@"
EOF
  cat >"${STUB_BIN}/umount" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${UMOUNT_LOG}"
EOF
  # mountpoint: report "is a mountpoint" so the unmount branch runs.
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"

  # Stub nm_flash_guard.sh so we don't touch real NetworkManager.
  NM_GUARD_BIN="${BATS_TEST_TMPDIR}/nm_flash_guard.sh"
  cat >"${NM_GUARD_BIN}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${NM_GUARD_LOG}"
EOF
  chmod +x "${NM_GUARD_BIN}"
  export NM_GUARD_BIN

  # Keep the unmount target inside the tmpdir (no real root writes).
  export L4T_EXPORT_DIR="${BATS_TEST_TMPDIR}/srv/jetson_l4t"

  # Redirect the usbcore sysfs writes to a writable tmp dir.
  USBCORE_PARAMS="${BATS_TEST_TMPDIR}/usbcore"
  mkdir -p "${USBCORE_PARAMS}"
  : >"${USBCORE_PARAMS}/autosuspend"
  : >"${USBCORE_PARAMS}/usbfs_memory_mb"
  export USBCORE_PARAMS

  # No watcher pidfile by default.
  export NM_GUARD_PIDFILE="${BATS_TEST_TMPDIR}/nm-guard.pid"
}

@test "host_teardown unmounts the bridge, restores USB defaults, re-enables NM" {
  run "${HOST_TEARDOWN}"
  assert_success

  run cat "${UMOUNT_LOG}"
  assert_output --partial "${L4T_EXPORT_DIR}"

  run cat "${USBCORE_PARAMS}/usbfs_memory_mb"
  assert_output '16'
  run cat "${USBCORE_PARAMS}/autosuspend"
  assert_output '2'

  run cat "${NM_GUARD_LOG}"
  assert_output 'enable'
}

@test "host_teardown skips unmount when the path is not a mountpoint" {
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  run "${HOST_TEARDOWN}"
  assert_success
  assert_output --partial 'not a mountpoint'
  [[ ! -s "${UMOUNT_LOG}" ]]   # umount never called
}

@test "host_teardown honors USB default overrides" {
  USBFS_MEMORY_MB_DEFAULT=8 USBCORE_AUTOSUSPEND_DEFAULT=5 run "${HOST_TEARDOWN}"
  assert_success
  run cat "${USBCORE_PARAMS}/usbfs_memory_mb"
  assert_output '8'
  run cat "${USBCORE_PARAMS}/autosuspend"
  assert_output '5'
}

@test "host_teardown stops a running auto watcher via its pidfile" {
  # Background a long sleep and record its PID as the watcher.
  sleep 300 &
  local wpid=$!
  printf '%s\n' "${wpid}" >"${NM_GUARD_PIDFILE}"

  run "${HOST_TEARDOWN}"
  assert_success
  assert_output --partial "stopped nm_flash_guard auto watcher (PID ${wpid})"

  # The watcher is killed and the pidfile removed.
  ! kill -0 "${wpid}" 2>/dev/null
  [[ ! -e "${NM_GUARD_PIDFILE}" ]]
}

@test "host_teardown is idempotent when nothing was set up" {
  # Not a mountpoint, no pidfile, guard file already gone.
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  rm -f "${NM_GUARD_PIDFILE}"
  run "${HOST_TEARDOWN}"
  assert_success
  [[ ! -s "${UMOUNT_LOG}" ]]
  run cat "${NM_GUARD_LOG}"
  assert_output 'enable'   # enable is still called (it is itself a no-op)
}
