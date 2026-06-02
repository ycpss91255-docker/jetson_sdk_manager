#!/usr/bin/env bats
#
# Unit tests for script/lib/usb.sh's pure helpers plus an end-to-end
# probe.sh smoke check (host without Jetson connected — should report
# "no devices" and exit 1).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install/lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${candidate}/usb.sh" ]]; then
      LIB_DIR="${candidate}"
      break
    fi
  done
  if [[ -z "${LIB_DIR:-}" ]]; then
    skip "script/lib/usb.sh not present in this image"
  fi

  for cand in \
      /opt/jetson_install/probe.sh \
      "${BATS_TEST_DIRNAME}/../../script/probe.sh"; do
    if [[ -x "${cand}" ]]; then
      PROBE_SH="${cand}"
      break
    fi
  done

  # shellcheck disable=SC1091
  . "${LIB_DIR}/usb.sh"
}

@test "JETSON_USB_VENDOR is the NVIDIA Corp ID" {
  [[ "${JETSON_USB_VENDOR}" == "0955" ]]
}

@test "known Orin recovery PIDs are accepted" {
  jetson_pid_is_recovery 7023  # AGX Orin
  jetson_pid_is_recovery 7223  # Orin NX / Nano
  jetson_pid_is_recovery 7423
  jetson_pid_is_recovery 7523
  jetson_pid_is_recovery 7e19
}

@test "non-recovery PIDs are rejected" {
  ! jetson_pid_is_recovery 0000
  ! jetson_pid_is_recovery 6000   # SDK Manager catalog board, not recovery
  ! jetson_pid_is_recovery 7022   # off-by-one
  ! jetson_pid_is_recovery ""
}

@test "recovery PID match is case-insensitive (uppercase hex from some lsusb builds)" {
  jetson_pid_is_recovery 7E19
  jetson_pid_is_recovery 7023
}

_stub_lsusb() {
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  printf '%s\n' '#!/usr/bin/env bash' "$1" >"${STUB_BIN}/lsusb"
  chmod +x "${STUB_BIN}/lsusb"
  export PATH="${STUB_BIN}:${PATH}"
}

@test "probe.sh exits 0 and reports recovery when an APX device is on the bus" {
  [[ -n "${PROBE_SH:-}" ]] || skip "probe.sh not present in this image"
  _stub_lsusb "printf 'Bus 001 Device 002: ID 0955:7023 NVIDIA Corp. APX\n'"
  run bash -c "'${PROBE_SH}' 2>&1"
  assert_success
  assert_output --partial 'recovery range'
}

@test "probe.sh exits non-zero when only a non-recovery NVIDIA device is present" {
  [[ -n "${PROBE_SH:-}" ]] || skip "probe.sh not present in this image"
  _stub_lsusb "printf 'Bus 001 Device 002: ID 0955:6000 NVIDIA Corp. Tegra\n'"
  run bash -c "'${PROBE_SH}' 2>&1"
  assert_failure
  assert_output --partial 'NOT in the recovery range'
}

@test "probe.sh exits non-zero when no Jetson is connected (devel-test host)" {
  [[ -n "${PROBE_SH:-}" ]] || skip "probe.sh not present in this image"
  command -v lsusb >/dev/null 2>&1 || skip "lsusb not on PATH"
  # CI / devel-test build runs on hosts without a real Jetson attached.
  # probe should therefore exit non-zero (no recovery device) and print
  # an action message. Don't assert specific output text — the visible
  # contract is the exit code.
  run "${PROBE_SH}"
  [[ "${status}" -ne 0 ]]
}
