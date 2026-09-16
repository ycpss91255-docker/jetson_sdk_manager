#!/usr/bin/env bats
#
# Integration tests for script/jetson.sh — the one-command entry point (#95).
# Everything it drives (make, host_setup.sh, nm_flash_guard.sh, lsusb, sudo,
# host_teardown.sh, clean.sh) is stubbed on PATH / via *_BIN overrides and
# records its argv, so the tests assert sequencing and gates, not behaviour
# that belongs to the underlying scripts.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install \
      "${BATS_TEST_DIRNAME}/../../script"; do
    if [[ -f "${candidate}/jetson.sh" ]]; then
      JETSON="${candidate}/jetson.sh"
      break
    fi
  done
  if [[ -z "${JETSON:-}" ]]; then
    skip "jetson.sh not present in this image"
  fi

  CALLS="${BATS_TEST_TMPDIR}/calls.log"; export CALLS
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  # Every stub appends "<name> <argv>" to one log so ORDER is observable.
  for name in make lsusb sudo; do
    cat >"${STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
printf '${name} %s\n' "\$*" >>"\${CALLS}"
EOF
  done
  # lsusb: LSUSB_OUT is what the bus looks like (default: nothing NVIDIA).
  cat >"${STUB_BIN}/lsusb" <<'EOF'
#!/usr/bin/env bash
printf 'lsusb %s\n' "$*" >>"${CALLS}"
# LSUSB_REC_AFTER=N: from the Nth call on, a board is in recovery.
n=$(grep -c '^lsusb' "${CALLS}")
if [[ -n "${LSUSB_REC_AFTER:-}" && "${n}" -ge "${LSUSB_REC_AFTER}" ]]; then
  printf 'Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX\n'
else
  printf '%s\n' "${LSUSB_OUT:-Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub}"
fi
EOF
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"

  # Sibling scripts jetson.sh calls by path: point them at loggers.
  for s in host_setup.sh init_data_dirs.sh nm_flash_guard.sh host_teardown.sh clean.sh; do
    cat >"${BATS_TEST_TMPDIR}/${s}" <<EOF
#!/usr/bin/env bash
printf '${s} %s\n' "\$*" >>"\${CALLS}"
EOF
    chmod +x "${BATS_TEST_TMPDIR}/${s}"
  done
  export HOST_SETUP_BIN="${BATS_TEST_TMPDIR}/host_setup.sh"
  export INIT_DATA_DIRS_BIN="${BATS_TEST_TMPDIR}/init_data_dirs.sh"
  export NM_GUARD_BIN="${BATS_TEST_TMPDIR}/nm_flash_guard.sh"
  export HOST_TEARDOWN_BIN="${BATS_TEST_TMPDIR}/host_teardown.sh"
  export CLEAN_BIN="${BATS_TEST_TMPDIR}/clean.sh"

  # Repo skeleton with a completed prepare (images phase recorded).
  export L4T_REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
  L4T_TREE="${L4T_REPO_ROOT}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T_TREE}"
  printf 'jetpack_version: "6.2.2"\nphases: [bsp, rootfs, binaries, user, network, images]\n' >"${L4T_TREE}/.prepared.yaml"

  REC='Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX'
  BOOTED='Bus 002 Device 009: ID 0955:7020 NVIDIA Corp. L4T (Linux for Tegra) running on Tegra'
}

# ── dispatch ─────────────────────────────────────────────────────────

@test "no argument prints help and does nothing" {
  run "${JETSON}"
  assert_success
  assert_output --partial 'Usage:'
  assert_output --partial 'status'
  [[ ! -e "${CALLS}" ]]
}

@test "unknown subcommand exits 2 with usage" {
  run "${JETSON}" frobnicate
  assert_failure 2
  assert_output --partial 'Usage:'
}

# ── flash ────────────────────────────────────────────────────────────

@test "flash fails fast when no Jetson is in recovery and never touches make or NM" {
  LSUSB_OUT="${BOOTED}" run "${JETSON}" flash
  assert_failure
  assert_output --partial 'wait-rec'
  run cat "${CALLS}"
  refute_output --partial 'make'
  refute_output --partial 'nm_flash_guard'
}

@test "flash with a board in recovery guards NM, then runs make run -t flash, then prints the ssh hint" {
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_success
  assert_output --partial '192.168.55.1'
  run cat "${CALLS}"
  assert_line --index 1 'nm_flash_guard.sh auto'
  assert_line --index 2 'make run -- -t flash'
}

@test "flash refuses when prepare has not recorded the images phase" {
  printf 'jetpack_version: "6.2.2"\nphases: [bsp, rootfs]\n' >"${L4T_TREE}/.prepared.yaml"
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_failure
  assert_output --partial 'prepare'
  run cat "${CALLS}"
  refute_output --partial 'make'
}

# ── wait-rec ─────────────────────────────────────────────────────────

@test "wait-rec prints the REC steps and returns as soon as a board appears in recovery" {
  WAIT_REC_INTERVAL=0.05 LSUSB_REC_AFTER=3 run "${JETSON}" wait-rec 10
  assert_success
  assert_output --partial 'Hold the REC button'
  assert_output --partial '0955:7023'
  [[ "$(grep -c '^lsusb' "${CALLS}")" -ge 3 ]]
}

@test "wait-rec times out with a non-zero exit and a hint" {
  WAIT_REC_INTERVAL=0.05 run "${JETSON}" wait-rec 1
  assert_failure
  assert_output --partial 'timed out'
}

@test "wait-rec rejects a non-numeric timeout" {
  run "${JETSON}" wait-rec soon
  assert_failure 2
}

# ── prepare ──────────────────────────────────────────────────────────

@test "prepare validates sudo once, then host_setup → init_data_dirs → make run -t prepare" {
  run "${JETSON}" prepare
  assert_success
  run cat "${CALLS}"
  assert_line --index 0 --regexp '^sudo (-n )?-v$'   # -n when there is no tty
  assert_line --index 1 'host_setup.sh '
  assert_line --index 2 'init_data_dirs.sh '
  assert_line --index 3 'make run -- -t prepare'
}

@test "prepare stops when host_setup fails and never reaches make" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"${HOST_SETUP_BIN}"
  run "${JETSON}" prepare
  assert_failure
  assert_output --partial 'host_setup'
  run cat "${CALLS}"
  refute_output --partial 'make'
}

# ── all ──────────────────────────────────────────────────────────────

@test "all runs prepare, waits for recovery, then flashes — in that order" {
  WAIT_REC_INTERVAL=0.05 LSUSB_REC_AFTER=2 run "${JETSON}" all
  assert_success
  assert_output --partial '[1/3]'
  assert_output --partial '[3/3]'
  run grep -vE '^(lsusb|sudo)' "${CALLS}"
  assert_line --index 0 'host_setup.sh '
  assert_line --index 1 'init_data_dirs.sh '
  assert_line --index 2 'make run -- -t prepare'
  assert_line --index 3 'nm_flash_guard.sh auto'
  assert_line --index 4 'make run -- -t flash'
}

@test "all stops after a failed prepare and tells the user how to resume" {
  printf '#!/usr/bin/env bash\nprintf "make %s\\n" "$*" >>"${CALLS}"; exit 1\n' >"${STUB_BIN}/make"
  WAIT_REC_INTERVAL=0.05 LSUSB_REC_AFTER=1 run "${JETSON}" all
  assert_failure
  assert_output --partial './jetson prepare'
  run cat "${CALLS}"
  refute_output --partial 'nm_flash_guard'
  refute_output --partial '-t flash'
}

# ── teardown / purge ─────────────────────────────────────────────────

@test "teardown calls host_teardown.sh" {
  run "${JETSON}" teardown
  assert_success
  run cat "${CALLS}"
  assert_output 'host_teardown.sh '
}

@test "purge asks for confirmation and aborts on anything but yes" {
  run bash -c "printf 'no\n' | '${JETSON}' purge"
  assert_failure
  assert_output --partial 'aborted'
  [[ ! -e "${CALLS}" ]]
}

@test "purge --yes skips the prompt and forwards --keep-downloads to clean.sh" {
  run "${JETSON}" purge --yes --keep-downloads
  assert_success
  run cat "${CALLS}"
  assert_output 'clean.sh purge --keep-downloads'
}
