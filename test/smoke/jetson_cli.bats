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
  for s in host_setup.sh init_data_dirs.sh nm_flash_guard.sh usb_ss_guard.sh host_teardown.sh clean.sh; do
    cat >"${BATS_TEST_TMPDIR}/${s}" <<EOF
#!/usr/bin/env bash
printf '${s} %s\n' "\$*" >>"\${CALLS}"
EOF
    chmod +x "${BATS_TEST_TMPDIR}/${s}"
  done
  export HOST_SETUP_BIN="${BATS_TEST_TMPDIR}/host_setup.sh"
  export INIT_DATA_DIRS_BIN="${BATS_TEST_TMPDIR}/init_data_dirs.sh"
  export NM_GUARD_BIN="${BATS_TEST_TMPDIR}/nm_flash_guard.sh"
  export USB_SS_GUARD_BIN="${BATS_TEST_TMPDIR}/usb_ss_guard.sh"
  export HOST_TEARDOWN_BIN="${BATS_TEST_TMPDIR}/host_teardown.sh"
  export CLEAN_BIN="${BATS_TEST_TMPDIR}/clean.sh"

  # Repo skeleton with a completed prepare (images phase recorded).
  export L4T_REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
  L4T_TREE="${L4T_REPO_ROOT}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T_TREE}"
  printf 'jetpack_version: "6.2.2"\nphases: [bsp, rootfs, binaries, user, network, images]\n' >"${L4T_TREE}/.prepared.yaml"

  # Healthy host fixtures for status (overridden per test where relevant).
  USBCORE_PARAMS="${BATS_TEST_TMPDIR}/usbcore"; mkdir -p "${USBCORE_PARAMS}"; export USBCORE_PARAMS
  printf -- '-1\n' >"${USBCORE_PARAMS}/autosuspend"; printf '2048\n' >"${USBCORE_PARAMS}/usbfs_memory_mb"
  NFSD_SYSFS="${BATS_TEST_TMPDIR}/nfsd"; mkdir -p "${NFSD_SYSFS}"; export NFSD_SYSFS
  # No SuperSpeed port parked (#100) — keep status hermetic on a host mid-flash.
  USB_SS_GUARD_TEST_ROOT="${BATS_TEST_TMPDIR}/ssroot"; export USB_SS_GUARD_TEST_ROOT
  STAT_BIN="${BATS_TEST_TMPDIR}/stat-ext4"; printf '#!/usr/bin/env bash\necho ext4\n' >"${STAT_BIN}"; chmod +x "${STAT_BIN}"; export STAT_BIN
  cat >"${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
# `docker info` ok; `docker image inspect` ok for any image.
exit 0
EOF
  cat >"${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
echo active
EOF
  chmod +x "${STUB_BIN}/docker" "${STUB_BIN}/systemctl"

  # Host NFS export (#101), in the lib's test mode: NFS_EXPORT_TEST_ROOT →
  # exportfs is <tmpdir>/bin/exportfs run WITHOUT sudo (logged into CALLS
  # so its place in the sequence is visible), the export dir is
  # <tmpdir>/srv/jetson_l4t (a symlink to the data dir here — the bridge),
  # the export table <tmpdir>/etab (absent by default). No host rpc.mountd
  # unless MOUNTD=1.
  export NFS_EXPORT_TEST_ROOT="${BATS_TEST_TMPDIR}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin" "${BATS_TEST_TMPDIR}/srv"
  cat >"${BATS_TEST_TMPDIR}/bin/exportfs" <<'EOF'
#!/usr/bin/env bash
printf 'exportfs %s\n' "$*" >>"${CALLS}"
EOF
  cat >"${STUB_BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *rpc.mountd* && -n "${MOUNTD:-}" ]] && { echo 4242; exit 0; }
exit 1
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/exportfs" "${STUB_BIN}/pgrep"
  ln -s "${L4T_REPO_ROOT}/data/jetson_l4t" "${BATS_TEST_TMPDIR}/srv/jetson_l4t"
  export L4T_EXPORT_DIR="${BATS_TEST_TMPDIR}/srv/jetson_l4t"
  L4T_HOST_TREE="${L4T_EXPORT_DIR}/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T_TREE}/rootfs" "${L4T_TREE}/tools/kernel_flash/images" "${L4T_TREE}/tools/kernel_flash/tmp"

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
  run grep -vE '^(lsusb|sudo|exportfs)' "${CALLS}"
  assert_line --index 0 'nm_flash_guard.sh auto'
  assert_line --index 2 'make run -- -t flash'
}

@test "flash order is nm_flash_guard auto → usb_ss_guard auto → make run -t flash (#100)" {
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_success
  run grep -vE '^(lsusb|sudo|exportfs)' "${CALLS}"
  assert_line --index 0 'nm_flash_guard.sh auto'
  assert_line --index 1 'usb_ss_guard.sh auto'
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
  LSUSB_OUT="${REC}" run "${JETSON}" prepare
  assert_success
  run grep -v '^lsusb' "${CALLS}"                     # the recovery preflight probes first (#97)
  assert_line --index 0 --regexp '^sudo (-n )?-v$'   # -n when there is no tty
  assert_line --index 1 'host_setup.sh '
  assert_line --index 2 'init_data_dirs.sh '
  assert_line --index 3 'make run -- -t prepare'
}

@test "prepare stops when host_setup fails and never reaches make" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"${HOST_SETUP_BIN}"
  LSUSB_OUT="${REC}" run "${JETSON}" prepare
  assert_failure
  assert_output --partial 'host_setup'
  run cat "${CALLS}"
  refute_output --partial 'make'
}

# ── all ──────────────────────────────────────────────────────────────

@test "all runs wait-rec, prepare, then flash — in that order" {
  WAIT_REC_INTERVAL=0.05 LSUSB_REC_AFTER=2 run "${JETSON}" all
  assert_success
  assert_output --partial '[1/3]'
  assert_output --partial '[3/3]'
  run grep -vE '^(lsusb|sudo|exportfs)' "${CALLS}"
  assert_line --index 0 'host_setup.sh '
  assert_line --index 1 'init_data_dirs.sh '
  assert_line --index 2 'make run -- -t prepare'
  assert_line --index 3 'nm_flash_guard.sh auto'
  assert_line --index 4 'usb_ss_guard.sh auto'
  assert_line --index 5 'make run -- -t flash'
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

# ── status ───────────────────────────────────────────────────────────

@test "status renders ✔/⚠/✘ lines and exits 0 when only warnings remain" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  password: jetson\n' >"${L4T_REPO_ROOT}/jetson.yaml"
  LSUSB_OUT="${BOOTED}" run "${JETSON}" status
  assert_success
  assert_output --partial '✔'
  assert_output --partial '⚠'
  assert_output --partial 'not in recovery'
}

@test "status exits 1 on a blocker (jetson.yaml missing)" {
  LSUSB_OUT="${REC}" run "${JETSON}" status
  assert_failure 1
  assert_output --partial '✘'
  assert_output --partial 'jetson.yaml'
}

@test "status --strict also fails on warnings" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  password: s3cret\n' >"${L4T_REPO_ROOT}/jetson.yaml"
  LSUSB_OUT="${BOOTED}" run "${JETSON}" status --strict
  assert_failure
  assert_output --partial 'strict'
}

# ── review round 1 ───────────────────────────────────────────────────

@test "flash refuses when more than one Jetson is in recovery" {
  LSUSB_OUT=$'Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX\nBus 001 Device 007: ID 0955:7523 NVIDIA Corp. APX' run "${JETSON}" flash
  assert_failure
  assert_output --partial '2 Jetsons in recovery'
  run cat "${CALLS}"
  refute_output --partial 'nm_flash_guard'
  refute_output --partial 'make'
}

@test "wait-rec times out on wall-clock time even when the interval is longer than the timeout" {
  SECONDS_BEFORE=$SECONDS
  WAIT_REC_INTERVAL=5 run "${JETSON}" wait-rec 1
  assert_failure
  assert_output --partial 'timed out'
  (( SECONDS - SECONDS_BEFORE < 4 ))
}

@test "wait-rec rejects a non-positive interval" {
  WAIT_REC_INTERVAL=0 run "${JETSON}" wait-rec 1
  assert_failure 2
  WAIT_REC_INTERVAL=abc run "${JETSON}" wait-rec 1
  assert_failure 2
}

@test "all: a Ctrl-C during flash is not reported as 'wait-rec interrupted' (trap restored)" {
  # make stub for flash: deliver INT to jetson.sh itself (the grandparent —
  # make runs inside a "(cd && make)" subshell) and die of INT so bash
  # propagates the signal up the wait chain like a real Ctrl-C would.
  cat >"${STUB_BIN}/make" <<'EOF'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >>"${CALLS}"
if [[ "$*" == *"-t flash"* ]]; then
  gp=$(awk '{print $4}' "/proc/${PPID}/stat")
  kill -INT "${gp}"; kill -INT "$$"; sleep 1
fi
EOF
  chmod +x "${STUB_BIN}/make"
  WAIT_REC_INTERVAL=0.05 LSUSB_REC_AFTER=1 run "${JETSON}" all
  assert_failure
  refute_output --partial 'wait-rec interrupted'
}

@test "status never prints 'ready' when a check dies mid-way" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  password: x\n' >"${L4T_REPO_ROOT}/jetson.yaml"
  JETSON_STATUS_CHECKS="status_config __no_such_check status_kernel" LSUSB_OUT="${REC}" run "${JETSON}" status
  assert_failure
  assert_output --partial 'internal: __no_such_check'
  refute_output --partial 'ready'
}

@test "flash refuses when several .prepared.yaml markers exist (ambiguous L4T tree)" {
  local other="${L4T_REPO_ROOT}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-orin-nano-devkit-super/Linux_for_Tegra"
  mkdir -p "${other}"; cp "${L4T_TREE}/.prepared.yaml" "${other}/"
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_failure
  assert_output --partial 'more than one'
  run cat "${CALLS}"
  refute_output --partial 'make'
}

@test "commands that take no arguments reject extra ones with exit 2" {
  run "${JETSON}" teardown now
  assert_failure 2
  [[ ! -e "${CALLS}" ]]
}

@test "wait-rec fails immediately (no polling loop) when two Jetsons are in recovery" {
  LSUSB_OUT=$'Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX\nBus 001 Device 007: ID 0955:7523 NVIDIA Corp. APX' \
    WAIT_REC_INTERVAL=0.05 run "${JETSON}" wait-rec 0
  assert_failure 1
  assert_output --partial '2 Jetsons in recovery'
  refute_output --partial 'timed out'
  [[ "$(grep -c '^lsusb' "${CALLS}")" -le 5 ]]     # one probe, not a loop (jetson_list_devices calls lsusb once per PID)
}

@test "flash with two Jetsons in recovery does not also claim 'no Jetson in recovery'" {
  LSUSB_OUT=$'Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX\nBus 001 Device 007: ID 0955:7523 NVIDIA Corp. APX' run "${JETSON}" flash
  assert_failure 1
  refute_output --partial 'no Jetson in recovery'
}

# ── #97: prepare needs the board in recovery ─────────────────────────

@test "prepare refuses when no Jetson is in recovery: step 10/10 reads the board spec over USB" {
  LSUSB_OUT="${BOOTED}" run "${JETSON}" prepare
  assert_failure
  assert_output --partial 'Hold the REC button'
  assert_output --partial 'board spec'
  run cat "${CALLS}"
  refute_output --partial 'make'
  refute_output --partial 'host_setup'
}

@test "prepare --no-board skips the recovery preflight for users exporting BOARDID/FAB/BOARDSKU/BOARDREV" {
  LSUSB_OUT="${BOOTED}" run "${JETSON}" prepare --no-board
  assert_success
  run cat "${CALLS}"
  assert_output --partial 'make run -- -t prepare'
}

@test "prepare with the board in recovery proceeds" {
  LSUSB_OUT="${REC}" run "${JETSON}" prepare
  assert_success
}

@test "all waits for recovery BEFORE prepare, then flashes" {
  WAIT_REC_INTERVAL=0.05 LSUSB_REC_AFTER=2 run "${JETSON}" all
  assert_success
  assert_output --partial '[1/3] wait for recovery'
  assert_output --partial '[2/3] prepare'
  assert_output --partial '[3/3] flash'
  run grep -vE '^(lsusb|sudo|exportfs)' "${CALLS}"
  assert_line --index 0 'host_setup.sh '
  assert_line --index 2 'make run -- -t prepare'
  assert_line --index 3 'nm_flash_guard.sh auto'
  assert_line --index 4 'usb_ss_guard.sh auto'
  assert_line --index 5 'make run -- -t flash'
}

@test "flash validates sudo once before the NetworkManager guard (nm_flash_guard needs root)" {
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_success
  run grep -vE '^(lsusb|exportfs)' "${CALLS}"
  assert_line --index 0 --regexp '^sudo (-n )?-v$'
  assert_line --index 1 'nm_flash_guard.sh auto'
}

# ── host NFS export (#101) ───────────────────────────────────────────

@test "flash re-exports the L4T tree from the host NFS server after sudo and before the NM guard (#101)" {
  # Every flash re-exports: a re-prepared images/ has a new file handle and
  # the old export would give the board 'mount.nfs: Stale file handle'.
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_success
  run grep -v '^lsusb' "${CALLS}"
  assert_line --index 0 --regexp '^sudo (-n )?-v$'
  assert_line --index 1 "exportfs -u [fc00:1:1::/48]:${L4T_HOST_TREE}/rootfs"
  assert_line --index 2 "exportfs -o rw,nohide,insecure,no_subtree_check,async,no_root_squash [fc00:1:1::/48]:${L4T_HOST_TREE}/rootfs"
  assert_line --index 4 --partial "[fc00:1:1::/48]:${L4T_HOST_TREE}/tools/kernel_flash/images"
  assert_line --index 6 --partial "[fc00:1:1::/48]:${L4T_HOST_TREE}/tools/kernel_flash/tmp"
  assert_line --index 7 'exportfs -f'
  assert_line --index 8 'nm_flash_guard.sh auto'
  assert_line --index 9 'usb_ss_guard.sh auto'
  assert_line --index 10 'make run -- -t flash'
}

@test "flash stops before the NM guard when the host export fails (rootfs missing behind the bridge)" {
  rm -rf "${L4T_TREE}/rootfs"
  LSUSB_OUT="${REC}" run "${JETSON}" flash
  assert_failure
  assert_output --partial 'Error [host-config]'
  run cat "${CALLS}"
  refute_output --partial 'nm_flash_guard'
  refute_output --partial 'make'
}

@test "status warns when a host rpc.mountd runs but the L4T tree is not exported — the #101 hang" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  password: s3cret\n' >"${L4T_REPO_ROOT}/jetson.yaml"
  # Export table (real format) with only rootfs in it.
  printf '%s/rootfs\tfc00:1:1::/48(rw,async,no_root_squash)\n' "${L4T_HOST_TREE}" >"${BATS_TEST_TMPDIR}/etab"
  MOUNTD=1 LSUSB_OUT="${REC}" run "${JETSON}" status
  assert_success
  assert_output --partial '⚠'
  assert_output --partial 'rpc.mountd'
  assert_output --partial 'not exporting'
  assert_output --partial 'kernel_flash/images: not exported'
  run cat "${CALLS}"
  refute_output --partial 'sudo'       # status never escalates
  refute_output --partial 'exportfs'   # read from the export table, exportfs never run
}

@test "status is ✔ when the host rpc.mountd exports all three rw to the flash client" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  password: s3cret\n' >"${L4T_REPO_ROOT}/jetson.yaml"
  local p
  for p in rootfs tools/kernel_flash/images tools/kernel_flash/tmp; do
    printf '%s/%s\tfc00:1:1::/48(rw,async,no_root_squash)\n' "${L4T_HOST_TREE}" "${p}" >>"${BATS_TEST_TMPDIR}/etab"
  done
  MOUNTD=1 LSUSB_OUT="${REC}" run "${JETSON}" status
  assert_success
  refute_output --partial 'not exporting'
  assert_output --partial 'exported rw to fc00:1:1::/48'
}

@test "status is quiet about NFS when the host has no rpc.mountd (the container serves NFS itself)" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  password: s3cret\n' >"${L4T_REPO_ROOT}/jetson.yaml"
  LSUSB_OUT="${REC}" run "${JETSON}" status
  assert_success
  refute_output --partial 'not exporting'
  assert_output --partial 'container serves NFS'
}
