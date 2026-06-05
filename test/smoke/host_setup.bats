#!/usr/bin/env bats
#
# Tests for script/host_setup.sh — the one-shot host prerequisites helper.
# docker / sudo / modprobe are stubbed on PATH and the usbcore sysfs path is
# redirected to a tmp dir so the script runs without root or real hardware.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install \
      "${BATS_TEST_DIRNAME}/../../script"; do
    if [[ -f "${candidate}/host_setup.sh" ]]; then
      HOST_SETUP="${candidate}/host_setup.sh"
      break
    fi
  done
  if [[ -z "${HOST_SETUP:-}" ]]; then
    skip "host_setup.sh not present in this image"
  fi

  DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  export DOCKER_LOG
  MODPROBE_LOG="${BATS_TEST_TMPDIR}/modprobe.log"
  export MODPROBE_LOG

  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_LOG}"
EOF
  # sudo: strip leading flags, then exec the rest (pass-through).
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do shift; done
exec "$@"
EOF
  cat >"${STUB_BIN}/modprobe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MODPROBE_LOG}"
EOF
  MOUNT_LOG="${BATS_TEST_TMPDIR}/mount.log"
  export MOUNT_LOG
  cat >"${STUB_BIN}/mount" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOUNT_LOG}"
EOF
  # mountpoint: report "not a mountpoint" so the bind branch runs.
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"

  # Keep the /srv bind step inside the tmpdir (no real root writes).
  export L4T_EXPORT_SRC="${BATS_TEST_TMPDIR}/data/jetson_l4t"
  export L4T_EXPORT_DIR="${BATS_TEST_TMPDIR}/srv/jetson_l4t"

  # Redirect the usbcore sysfs writes to a writable tmp dir.
  USBCORE_PARAMS="${BATS_TEST_TMPDIR}/usbcore"
  mkdir -p "${USBCORE_PARAMS}"
  : >"${USBCORE_PARAMS}/autosuspend"
  : >"${USBCORE_PARAMS}/usbfs_memory_mb"
  export USBCORE_PARAMS
}

@test "host_setup registers qemu, loads nfsd, and applies the USB tweaks" {
  run "${HOST_SETUP}"
  assert_success

  run cat "${DOCKER_LOG}"
  assert_output --partial 'qemu-user-static'
  assert_output --partial '--reset'

  run cat "${MODPROBE_LOG}"
  assert_output 'nfsd'

  run cat "${USBCORE_PARAMS}/autosuspend"
  assert_output -- '-1'
  run cat "${USBCORE_PARAMS}/usbfs_memory_mb"
  assert_output '2048'

  run cat "${MOUNT_LOG}"
  assert_output --partial '--bind'
  assert_output --partial "${L4T_EXPORT_DIR}"
}

@test "host_setup skips the bind when /srv is already a mountpoint" {
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'already bind-mounted'
  [[ ! -s "${MOUNT_LOG}" ]]   # mount never called
}

@test "host_setup honors USBFS_MEMORY_MB override" {
  USBFS_MEMORY_MB=4096 run "${HOST_SETUP}"
  assert_success
  run cat "${USBCORE_PARAMS}/usbfs_memory_mb"
  assert_output '4096'
}

@test "host_setup still loads nfsd + USB tweaks when docker is absent" {
  # Point DOCKER_BIN at a name that resolves nowhere, so the docker branch is
  # skipped deterministically without depending on the host's real docker.
  DOCKER_BIN=__no_docker_here__ run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'docker not found'
  run cat "${MODPROBE_LOG}"
  assert_output 'nfsd'
  run cat "${USBCORE_PARAMS}/autosuspend"
  assert_output -- '-1'
}
