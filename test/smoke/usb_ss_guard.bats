#!/usr/bin/env bats
#
# Unit tests for script/usb_ss_guard.sh (#100) — disable the SuperSpeed half
# of the Jetson's USB-C connector for the initrd flash. sysfs is a fixture
# tree under the test tmpdir (USB_SYSFS), the state dir is a tmpdir
# (USB_SS_GUARD_STATE_DIR), sudo is a pass-through stub and lsusb is stubbed
# for the watcher, so nothing here needs root or hardware.
#
# Fixture mirrors this host (issue #100): the recovery device enumerates at
# high speed as 3-1 on root hub usb3 (speed 480; usb3-port1, location
# 0x80000002); the SuperSpeed half of the same physical connector is
# usb2-port3 on root hub usb2 (speed 20000), which carries the same
# location. Another connector (0x80000001), an unused port and a downstream
# hub whose ports report location 0x00000000 are present as decoys.

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
  # Not pre-created: the guard makes it (root-owned 0755 for real; ours here).
  STATE_DIR="${BATS_TEST_TMPDIR}/run/usb-ss-guard"
  export USB_SS_GUARD_STATE_DIR="${STATE_DIR}"
  STATE="${STATE_DIR}/state"
  PIDFILE="${STATE_DIR}/watch.pid"
  FAILED="${STATE_DIR}/watch.failed"
  export USB_SS_GUARD_POLL_INTERVAL=1

  # Root hubs: <name> <speed>
  _mk_hub usb1 480
  _mk_hub usb2 20000
  _mk_hub usb3 480
  _mk_hub usb4 20000
  # Root hub ports: <bus> <port> <location>
  _mk_port 3 1 0x80000002   # HS half, the Jetson is here
  _mk_port 3 5 0x80000001   # HS half of another connector
  _mk_port 2 3 0x80000002   # SS half of the Jetson's connector
  _mk_port 2 1 0x80000001   # SS half of the other connector
  _mk_port 2 2 0x80000000   # not used
  _mk_port 1 1 0x80000000
  _mk_port 4 1 0x80000000
  # Downstream hub on the other connector: its ports have no ACPI location.
  _mk_hubport 2-1 1 0x00000000
  _mk_hubport 3-5 1 0x00000000
  # Devices: <dir> <idVendor> <idProduct> <busnum> <devnum> <speed>
  _mk_dev 3-1 0955 7023 3 17 480    # Jetson in recovery (APX), high speed
  _mk_dev 2-1 0bda 0411 2 2 5000    # a dock hub on the other connector (SS)
  _mk_dev 3-5 0bda 5411 3 3 480     # its HS half

  JETSON_SS_PORT="${SYS}/usb2/2-0:1.0/usb2-port3"
  JETSON_HS_PORT="${SYS}/usb3/3-0:1.0/usb3-port1"
  OTHER_SS_PORT="${SYS}/usb2/2-0:1.0/usb2-port1"
  OTHER_HS_PORT="${SYS}/usb3/3-0:1.0/usb3-port5"

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

# Kill any watcher a test left behind (they are children of this bats
# process, identified by the script path under test, never anything else).
teardown() {
  pkill -f "${GUARD_SH} _watch" 2>/dev/null || true
}

_mk_hub() {
  mkdir -p "${SYS}/$1"
  printf '%s\n' "$2" >"${SYS}/$1/speed"
  printf '1d6b\n' >"${SYS}/$1/idVendor"
  printf '0003\n' >"${SYS}/$1/idProduct"
}

# _mk_port <bus> <port> <location> → usbN/N-0:1.0/usbN-portM (root hub port)
_mk_port() {
  local dir="${SYS}/usb$1/$1-0:1.0/usb$1-port$2"
  mkdir -p "${dir}"
  printf '%s\n' "$3" >"${dir}/location"
  printf '0\n' >"${dir}/disable"
  printf 'hotplug\n' >"${dir}/connect_type"
}

# _mk_hubport <hub dev> <port> <location> → N-M/N-M:1.0/N-M-portX
_mk_hubport() {
  local dir="${SYS}/$1/$1:1.0/$1-port$2"
  mkdir -p "${dir}"
  printf '%s\n' "$3" >"${dir}/location"
  printf '0\n' >"${dir}/disable"
}

_mk_dev() {
  local dir="${SYS}/$1"
  mkdir -p "${dir}"
  printf '%s\n' "$2" >"${dir}/idVendor"
  printf '%s\n' "$3" >"${dir}/idProduct"
  printf '%s\n' "$4" >"${dir}/busnum"
  printf '%s\n' "$5" >"${dir}/devnum"
  printf '%s\n' "$6" >"${dir}/speed"
}

_state_port()  { sed -n 's/^port=//p' "${STATE}"; }
_state_token() { sed -n 's/^token=//p' "${STATE}"; }
# sudo that reports success but writes nothing (the read-back must catch it).
_stub_sudo_noop() {
  local d="${BATS_TEST_TMPDIR}/stub-noop"
  mkdir -p "${d}"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1; exit 0' >"${d}/sudo"
  chmod +x "${d}/sudo"
  export PATH="${d}:${PATH}"
}
# _wait_for <seconds> <bash test> — poll until the test passes.
_wait_for() {
  local i
  for i in $(seq 1 $(( $1 * 4 ))); do
    eval "$2" && return 0
    sleep 0.25
  done
  return 1
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

@test "auto rejects a timeout that is not a positive integer, before touching anything" {
  local t
  for t in 0 -5 '' ' ' abc 1.5; do
    run bash -c "'${GUARD_SH}' auto '${t}' 2>&1"
    assert_failure 2
    assert_output --partial 'timeout'
    [[ ! -e "${STATE}" ]]
    run cat "${JETSON_SS_PORT}/disable"
    assert_output '0'
  done
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
  run cat "${OTHER_SS_PORT}/disable"
  assert_output '0'
  run cat "${OTHER_HS_PORT}/disable"
  assert_output '0'
}

@test "disable records the disabled port (root-hub shape) and a token in the state file" {
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  [[ -f "${STATE}" ]]
  [[ "$(_state_port)" == "${JETSON_SS_PORT}" ]]
  [[ "$(_state_token)" =~ ^[0-9a-f]+$ ]]
}

@test "disable is idempotent: a second run leaves the port disabled and the same port recorded" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'already disabled'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  [[ "$(_state_port)" == "${JETSON_SS_PORT}" ]]
}

@test "disable with no Jetson on the bus is a no-op with a message (exit 0)" {
  rm -rf "${SYS}/3-1"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'no Jetson'
  [[ ! -e "${STATE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "disable with no SuperSpeed sibling (USB-2-only cable) is a no-op with a message (exit 0)" {
  rm -rf "${JETSON_SS_PORT}"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'no SuperSpeed sibling'
  assert_output --partial 'usb3-port1'
  [[ ! -e "${STATE}" ]]
  run cat "${OTHER_SS_PORT}/disable"
  assert_output '0'
}

@test "disable with the Jetson behind a hub says so and writes nothing (exit 0)" {
  rm -rf "${SYS}/3-1"
  _mk_hubport 2-1 4 0x00000000
  _mk_dev 2-1.4 0955 7023 2 9 480
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'behind a hub'
  [[ ! -e "${STATE}" ]]
  run cat "${SYS}/2-1/2-1:1.0/2-1-port1/disable"
  assert_output '0'
}

@test "disable when the sibling port has no 'disable' attribute (old kernel) is a no-op with a message (exit 0)" {
  rm -f "${JETSON_SS_PORT}/disable"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial "no 'disable' attribute"
  [[ ! -e "${STATE}" ]]
  [[ ! -e "${JETSON_SS_PORT}/disable" ]]
}

@test "disable also anchors on the initrd flash device (0955:7035) for a flash already in progress" {
  printf '7035\n' >"${SYS}/3-1/idProduct"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
}

@test "disable refuses when two SS ports share the anchor's location (ambiguous) and writes nothing" {
  _mk_port 4 1 0x80000002
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'more than one'
  [[ ! -e "${STATE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
  run cat "${SYS}/usb4/4-0:1.0/usb4-port1/disable"
  assert_output '0'
}

@test "disable with the Jetson already on the SuperSpeed side never disables the HS half" {
  rm -rf "${SYS}/3-1"
  _mk_dev 2-3 0955 7035 2 21 10000   # enumerated at SS on usb2-port3
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'SuperSpeed'
  [[ ! -e "${STATE}" ]]
  run cat "${JETSON_HS_PORT}/disable"
  assert_output '0'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "disable ignores a same-location port on another high-speed root hub (not an SS half)" {
  rm -rf "${JETSON_SS_PORT}"
  _mk_port 1 1 0x80000002   # usb1 is speed 480
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'no SuperSpeed sibling'
  run cat "${SYS}/usb1/1-0:1.0/usb1-port1/disable"
  assert_output '0'
}

@test "disable fails (exit 1, no state) when the sudo write does not take" {
  _stub_sudo_noop
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_failure 1
  assert_output --partial 'could not'
  [[ ! -e "${STATE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "disable treats a state file whose port is not actually disabled as stale: clears it and proceeds" {
  mkdir -p "${STATE_DIR}"
  printf 'port=%s\ntoken=deadbeef\n' "${OTHER_SS_PORT}" >"${STATE}"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_success
  assert_output --partial 'stale'
  [[ "$(_state_port)" == "${JETSON_SS_PORT}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  run cat "${OTHER_SS_PORT}/disable"
  assert_output '0'
}

@test "disable refuses (exit 1) a state file whose port path is not a root-hub port under USB_SYSFS" {
  mkdir -p "${STATE_DIR}"
  printf 'port=%s\ntoken=deadbeef\n' "${BATS_TEST_TMPDIR}/elsewhere" >"${STATE}"
  run bash -c "'${GUARD_SH}' disable 2>&1"
  assert_failure 1
  assert_output --partial 'not a valid'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

# ── enable ───────────────────────────────────────────────────────────

@test "enable restores exactly the recorded port and removes the state file" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial 'usb2-port3'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
  [[ ! -e "${STATE}" ]]
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
  _stub_sudo_noop
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_failure 1
  assert_output --partial 'could not re-enable'
  [[ -e "${STATE}" ]]
}

@test "enable refuses a state path outside USB_SYSFS (exit 1, nothing written, state kept)" {
  mkdir -p "${STATE_DIR}" "${BATS_TEST_TMPDIR}/victim"
  printf 'secret\n' >"${BATS_TEST_TMPDIR}/victim/disable"
  printf 'port=%s\ntoken=deadbeef\n' "${BATS_TEST_TMPDIR}/victim" >"${STATE}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_failure 1
  assert_output --partial 'not a valid'
  run cat "${BATS_TEST_TMPDIR}/victim/disable"
  assert_output 'secret'
  [[ -e "${STATE}" ]]
}

@test "enable refuses a state path that is a symlink out of the port tree (exit 1, target untouched)" {
  mkdir -p "${STATE_DIR}" "${BATS_TEST_TMPDIR}/victim"
  printf 'secret\n' >"${BATS_TEST_TMPDIR}/victim/disable"
  ln -s "${BATS_TEST_TMPDIR}/victim" "${SYS}/usb2/2-0:1.0/usb2-port9"
  printf 'port=%s\ntoken=deadbeef\n' "${SYS}/usb2/2-0:1.0/usb2-port9" >"${STATE}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_failure 1
  assert_output --partial 'not a valid'
  run cat "${BATS_TEST_TMPDIR}/victim/disable"
  assert_output 'secret'
}

@test "enable refuses a state path whose bus numbers disagree (usb2/3-0:1.0/usb2-port3)" {
  mkdir -p "${STATE_DIR}" "${SYS}/usb2/3-0:1.0/usb2-port3"
  printf '1\n' >"${SYS}/usb2/3-0:1.0/usb2-port3/disable"
  printf 'port=%s\ntoken=deadbeef\n' "${SYS}/usb2/3-0:1.0/usb2-port3" >"${STATE}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_failure 1
  run cat "${SYS}/usb2/3-0:1.0/usb2-port3/disable"
  assert_output '1'
}

@test "enable refuses a malformed state file (exit 1)" {
  mkdir -p "${STATE_DIR}"
  printf 'garbage\n' >"${STATE}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_failure 1
  assert_output --partial 'not a valid'
}

@test "enable with a stale state (port already enabled) clears it with a message (exit 0)" {
  mkdir -p "${STATE_DIR}"
  printf 'port=%s\ntoken=deadbeef\n' "${JETSON_SS_PORT}" >"${STATE}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial 'stale'
  [[ ! -e "${STATE}" ]]
}

@test "enable stops a running watcher (verified via /proc cmdline) before restoring the port" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  bash "${GUARD_SH}" _watch 300 "$(_state_token)" >/dev/null 2>&1 </dev/null &
  _wait_for 5 "[[ -s '${PIDFILE}' ]]"
  local wpid
  wpid="$(head -n1 "${PIDFILE}")"
  [[ -d "/proc/${wpid}" ]]
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial "stopped watcher (PID ${wpid})"
  _wait_for 5 "[[ ! -d '/proc/${wpid}' ]]"
  [[ ! -e "${PIDFILE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "enable never kills a PID from the pidfile that is not a usb_ss_guard watcher" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  sleep 300 >/dev/null 2>&1 </dev/null &
  local other=$!
  printf '%s\n' "${other}" >"${PIDFILE}"
  run bash -c "'${GUARD_SH}' enable 2>&1"
  assert_success
  assert_output --partial 'not a usb_ss_guard watcher'
  [[ -d "/proc/${other}" ]]
  [[ ! -e "${PIDFILE}" ]]
  kill "${other}" 2>/dev/null || true
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

@test "status reports a stale state (port recorded but reads 0)" {
  mkdir -p "${STATE_DIR}"
  printf 'port=%s\ntoken=deadbeef\n' "${JETSON_SS_PORT}" >"${STATE}"
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_success
  assert_output --partial 'stale'
}

# ── watcher / auto ───────────────────────────────────────────────────

@test "_watch re-enables the port as soon as the booted PID (0955:7020) appears" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  LSUSB_OUT='Bus 003 Device 003: ID 0955:7020 NVIDIA Corp. L4T' \
    run bash -c "'${GUARD_SH}' _watch 30 '$(_state_token)' 2>&1"
  assert_success
  assert_output --partial 'Jetson booted'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
  [[ ! -e "${STATE}" ]]
  [[ ! -e "${PIDFILE}" ]]
}

@test "_watch times out and re-enables the port on an empty bus" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' _watch 1 '$(_state_token)' 2>&1"
  assert_success
  assert_output --partial 'timed out'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "_watch with a superseded token leaves the port and the state alone" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  run bash -c "'${GUARD_SH}' _watch 1 'notthetoken' 2>&1"
  assert_success
  assert_output --partial 'superseded'
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  [[ -e "${STATE}" ]]
  [[ ! -e "${PIDFILE}" ]]
}

@test "_watch leaves a .failed marker when it cannot re-enable, and status shows it" {
  bash -c "'${GUARD_SH}' disable" 2>/dev/null
  local tok
  tok="$(_state_token)"
  _stub_sudo_noop
  run bash -c "'${GUARD_SH}' _watch 1 '${tok}' 2>&1"
  assert_success
  [[ -e "${FAILED}" ]]
  [[ -e "${STATE}" ]]
  run bash -c "'${GUARD_SH}' status 2>&1"
  assert_output --partial 'could not re-enable'
}

@test "auto with nothing to disable starts no watcher" {
  rm -rf "${SYS}/3-1"
  run bash -c "'${GUARD_SH}' auto 2>&1"
  assert_success
  assert_output --partial 'no Jetson'
  [[ ! -e "${PIDFILE}" ]]
}

@test "auto disables the port, the watcher has written its pidfile by the time auto returns, and restores on timeout" {
  run bash -c "'${GUARD_SH}' auto 1 2>&1"
  assert_success
  assert_output --partial 'watcher PID'
  [[ -s "${PIDFILE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
  _wait_for 10 "[[ ! -e '${STATE}' ]]"
  [[ ! -e "${PIDFILE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "auto when the board is already booted leaves no stale pidfile behind" {
  LSUSB_OUT='Bus 003 Device 003: ID 0955:7020 NVIDIA Corp. L4T' \
    run bash -c "'${GUARD_SH}' auto 30 2>&1"
  assert_success
  _wait_for 10 "[[ ! -e '${STATE}' && ! -e '${PIDFILE}' ]]"
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '0'
}

@test "a second auto replaces the running watcher instead of stacking another" {
  run bash -c "'${GUARD_SH}' auto 300 2>&1"
  assert_success
  local pid1
  pid1="$(head -n1 "${PIDFILE}")"
  run bash -c "'${GUARD_SH}' auto 300 2>&1"
  assert_success
  assert_output --partial "stopped watcher (PID ${pid1})"
  local pid2
  pid2="$(head -n1 "${PIDFILE}")"
  [[ "${pid2}" != "${pid1}" ]]
  _wait_for 5 "[[ ! -d '/proc/${pid1}' ]]"
  [[ -d "/proc/${pid2}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
}

@test "auto warns and leaves the port parked when the root watcher cannot be started (sudo -n refused)" {
  local d="${BATS_TEST_TMPDIR}/stub-nosudo-n"
  mkdir -p "${d}"
  # sudo -n (the watcher spawn) is refused; plain sudo (the sysfs writes) passes through.
  printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == -n ]] && exit 1' \
    'while [[ "$1" == -* ]]; do shift; done' 'exec "$@"' >"${d}/sudo"
  chmod +x "${d}/sudo"
  PATH="${d}:${PATH}" run bash -c "'${GUARD_SH}' auto 30 2>&1"
  assert_success
  assert_output --partial 'could not start'
  assert_output --partial 'enable'
  [[ ! -e "${PIDFILE}" ]]
  [[ -e "${STATE}" ]]
  run cat "${JETSON_SS_PORT}/disable"
  assert_output '1'
}
