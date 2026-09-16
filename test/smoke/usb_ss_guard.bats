#!/usr/bin/env bats
#
# Unit tests for script/usb_ss_guard.sh (#100) — disable the SuperSpeed half
# of the Jetson's USB-C connector for the initrd flash. sysfs is a fixture
# tree under the test tmpdir (USB_SYSFS), sudo is a pass-through stub and
# lsusb is stubbed for the watcher, so nothing here needs root or hardware.
#
# Fixture mirrors this host (issue #100): the recovery device enumerates at
# high speed as 3-1 on root hub usb3 (usb3-port1, location 0x80000002); the
# SuperSpeed half of the same physical connector is usb2-port3 on root hub
# usb2, which carries the same location. Another connector (0x80000001)
# and a downstream hub whose ports report location 0x00000000 are present
# so the peer lookup has decoys.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for cand in \
      /opt/jetson_install/usb_ss_guard.sh \
      "${BATS_TEST_DIRNAME}/../../script/usb_ss_guard.sh"; do
    if [[ -x "${cand}" ]]; then
      GUARD_SH="${cand}"
      break
    fi
  done
  [[ -n "${GUARD_SH:-}" ]] || skip "script/usb_ss_guard.sh not present in this image"

  SYS="${BATS_TEST_TMPDIR}/sysfs"
  export USB_SYSFS="${SYS}"
  export USB_SS_GUARD_STATE="${BATS_TEST_TMPDIR}/guard.state"
  export USB_SS_GUARD_PIDFILE="${BATS_TEST_TMPDIR}/watch.pid"
  export USB_SS_GUARD_POLL_INTERVAL=1

  # Root hub ports: <interface dir> <port name> <location>
  _mk_port 3-0:1.0 usb3-port1 0x80000002   # HS half, the Jetson is here
  _mk_port 3-0:1.0 usb3-port5 0x80000001   # HS half of another connector
  _mk_port 2-0:1.0 usb2-port3 0x80000002   # SS half of the Jetson's connector
  _mk_port 2-0:1.0 usb2-port1 0x80000001   # SS half of the other connector
  _mk_port 2-0:1.0 usb2-port2 0x80000000   # not used
  # Downstream hub on the other connector: ports have no ACPI location.
  _mk_port 2-1:1.0 2-1-port1 0x00000000
  _mk_port 3-5:1.0 3-5-port1 0x00000000
  # Devices: <dir> <idVendor> <idProduct> <busnum> <devnum>
  _mk_dev 3-1 0955 7023 3 17    # Jetson in recovery (APX), high speed
  _mk_dev 2-1 0bda 0411 2 2     # a dock hub on the other connector
  _mk_dev 3-5 0bda 5411 3 3

  JETSON_SS_PORT="${SYS}/2-0:1.0/usb2-port3"
  JETSON_HS_PORT="${SYS}/3-0:1.0/usb3-port1"

  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  # sudo: strip leading flags, exec the rest (the fixture files are writable).
  printf '%s\n' '#!/usr/bin/env bash' 'while [[ "$1" == -* ]]; do shift; done' 'exec "$@"' \
    >"${STUB_BIN}/sudo"
  # lsusb: LSUSB_OUT is what the bus looks like (default: nothing NVIDIA).
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${LSUSB_OUT:-}"' >"${STUB_BIN}/lsusb"
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"
}

_mk_port() {
  local dir="${SYS}/$1/$2"
  mkdir -p "${dir}"
  printf '%s\n' "$3" >"${dir}/location"
  printf '0\n' >"${dir}/disable"
  printf 'hotplug\n' >"${dir}/connect_type"
}

_mk_dev() {
  local dir="${SYS}/$1"
  mkdir -p "${dir}"
  printf '%s\n' "$2" >"${dir}/idVendor"
  printf '%s\n' "$3" >"${dir}/idProduct"
  printf '%s\n' "$4" >"${dir}/busnum"
  printf '%s\n' "$5" >"${dir}/devnum"
}

# ── dispatch ─────────────────────────────────────────────────────────

@test "unknown subcommand exits 2 and the usage lists disable/enable/status/auto" {
  run bash -c "'${GUARD_SH}' bogus 2>&1"
  assert_failure 2
  assert_output --partial 'disable'
  assert_output --partial 'enable'
  assert_output --partial 'status'
  assert_output --partial 'auto'
}

# ── disable ──────────────────────────────────────────────────────────

@test "disable resolves the SS sibling by location and writes 1 to ONLY that port" {
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'usb2-port3'
  assert_output --partial '0x80000002'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  # The HS half the Jetson is on, and every other port, stay enabled.
  run cat "${JETSON_HS_PORT}/disable"
  assert_output '0'
  run cat "${SYS}/2-0:1.0/usb2-port1/disable"
  assert_output '0'
  run cat "${SYS}/3-0:1.0/usb3-port5/disable"
  assert_output '0'
}

@test "disable records the disabled port in the state file so enable is exact" {
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  [[ -f "${USB_SS_GUARD_STATE}" ]]
  run cat "${USB_SS_GUARD_STATE}"
  assert_output "${JETSON_SS_PORT}"
}

@test "disable is idempotent: a second run leaves the port disabled and the state unchanged" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'already disabled'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  run cat "${USB_SS_GUARD_STATE}"
  assert_output "${JETSON_SS_PORT}"
}

@test "disable with no Jetson on the bus is a no-op with a message (exit 0)" {
  rm -rf "${SYS}/3-1"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'no Jetson'
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "disable with no SuperSpeed sibling (USB-2-only cable / hub) is a no-op with a message (exit 0)" {
  rm -rf "${JETSON_SS_PORT}"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'no SuperSpeed sibling'
  assert_output --partial 'usb3-port1'
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
  # Decoys (other connector, location-less hub ports) are untouched.
  run cat "${SYS}/2-0:1.0/usb2-port1/disable"
  assert_output '0'
  run cat "${SYS}/2-1:1.0/2-1-port1/disable"
  assert_output '0'
}

@test "disable behind a hub (port location 0x00000000) does not pair location-less ports" {
  # Jetson downstream of the dock hub: 2-1.4 → hub 2-1, port 4, no ACPI location.
  rm -rf "${SYS}/3-1"
  _mk_port 2-1:1.0 2-1-port4 0x00000000
  _mk_dev 2-1.4 0955 7023 2 9
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'no SuperSpeed sibling'
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
  run cat "${SYS}/2-1:1.0/2-1-port1/disable"
  assert_output '0'
}

@test "disable when the sibling port has no 'disable' attribute (old kernel) is a no-op with a message (exit 0)" {
  rm -f "${JETSON_SS_PORT}/disable"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial "no 'disable' attribute"
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
  [[ ! -e "${JETSON_SS_PORT}/disable" ]]
}

@test "disable also anchors on the initrd flash device (0955:7035) for a flash already in progress" {
  printf '7035\n' >"${SYS}/3-1/idProduct"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
}

# ── enable ───────────────────────────────────────────────────────────

@test "enable restores exactly the recorded port and removes the state file" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial 'usb2-port3'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
}

@test "enable without a state file is a no-op (exit 0)" {
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial 'nothing to re-enable'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "enable fails (exit 1, state kept) when the write does not take" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  # sudo that claims success but writes nothing: the port stays disabled.
  local stub2="${BATS_TEST_TMPDIR}/stub2"
  mkdir -p "${stub2}"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null; exit 0' >"${stub2}/sudo"
  chmod +x "${stub2}/sudo"
  PATH="${stub2}:${PATH}" run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_failure
  assert_output --partial 'could not re-enable'
  [[ -e "${USB_SS_GUARD_STATE}" ]]
}

# ── status ───────────────────────────────────────────────────────────

@test "status reports ENABLED when nothing is disabled" {
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'ENABLED'
}

@test "status reports DISABLED with the port after disable" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'DISABLED'
  assert_output --partial 'usb2-port3'
}

# ── watcher / auto ───────────────────────────────────────────────────

@test "_watch re-enables the port as soon as the booted PID (0955:7020) appears" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  LSUSB_OUT='Bus 003 Device 003: ID 0955:7020 NVIDIA Corp. L4T' \
    run bash -c "'${GUARD_SH}' _watch 30 2>&1"
  assert_success
  assert_output --partial 'Jetson booted'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
}

@test "_watch times out and re-enables the port on an empty bus" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' _watch 1 2>&1"
  assert_success
  assert_output --partial 'timed out'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "_watch leaves a .failed marker when it cannot re-enable" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  local stub2="${BATS_TEST_TMPDIR}/stub2"
  mkdir -p "${stub2}"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null; exit 0' >"${stub2}/sudo"
  chmod +x "${stub2}/sudo"
  PATH="${stub2}:${PATH}" run bash -c "'${GUARD_SH}' _watch 1 2>&1"
  assert_success
  [[ -e "${USB_SS_GUARD_PIDFILE}.failed" ]]
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_output --partial 'could not re-enable'
}

@test "auto with nothing to disable starts no watcher" {
  rm -rf "${SYS}/3-1"
  run bash -c "'${GUARD_SH}' auto 2>&1"
  assert_success
  assert_output --partial 'no Jetson'
  [[ ! -e "${USB_SS_GUARD_PIDFILE}" ]]
}

@test "auto disables the port and the detached watcher restores it on timeout" {
  run bash -c "'${GUARD_SH}' auto 1 2>&1"
  assert_success
  assert_output --partial 'watcher PID'
  [[ -e "${USB_SS_GUARD_PIDFILE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  # The watcher polls every 1 s and times out after 1 s.
  local i
  for i in $(seq 1 20); do
    [[ -e "${USB_SS_GUARD_STATE}" ]] || break
    sleep 0.5
  done
  [[ ! -e "${USB_SS_GUARD_STATE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}
