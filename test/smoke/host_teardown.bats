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
  USB_SS_GUARD_LOG="${BATS_TEST_TMPDIR}/usb_ss_guard.log"
  export USB_SS_GUARD_LOG

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
  # Stub usb_ss_guard.sh likewise (#100) — no real sysfs port writes.
  USB_SS_GUARD_BIN="${BATS_TEST_TMPDIR}/usb_ss_guard.sh"
  cat >"${USB_SS_GUARD_BIN}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${USB_SS_GUARD_LOG}"
EOF
  chmod +x "${USB_SS_GUARD_BIN}"
  export USB_SS_GUARD_BIN

  # Keep the unmount target inside the tmpdir (no real root writes).
  export L4T_EXPORT_DIR="${BATS_TEST_TMPDIR}/srv/jetson_l4t"
  mkdir -p "${L4T_EXPORT_DIR}"
  # Store (#93): repo root in the tmpdir with a provisioned loop-image store.
  export L4T_REPO_ROOT="${BATS_TEST_TMPDIR}"
  STORE_DATA="${BATS_TEST_TMPDIR}/data/jetson_l4t"
  STORE_IMG="${BATS_TEST_TMPDIR}/data/jetson_l4t.img"
  STORE_MARKER="${BATS_TEST_TMPDIR}/data/.l4t_store"
  mkdir -p "${STORE_DATA}"
  : >"${STORE_IMG}"
  printf 'version=1\nbackend=loop-image\nrepo_id=x\nimage=%s\n' "${STORE_IMG}" >"${STORE_MARKER}"
  # rmdir stub so the /srv cleanup is observable without root.
  RMDIR_LOG="${BATS_TEST_TMPDIR}/rmdir.log"; export RMDIR_LOG
  cat >"${STUB_BIN}/rmdir" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RMDIR_LOG}"
/bin/rmdir "$@"
EOF
  chmod +x "${STUB_BIN}/rmdir"

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

# ── USB SuperSpeed guard (#100) ──────────────────────────────────────

@test "host_teardown re-enables the connector's SuperSpeed half via usb_ss_guard.sh enable (which stops its own watcher)" {
  run "${HOST_TEARDOWN}"
  assert_success
  assert_output --partial '7/7'
  run cat "${USB_SS_GUARD_LOG}"
  assert_output 'enable'
}

# ── store (#93) ──────────────────────────────────────────────────────

@test "host_teardown unmounts /srv first, then the repo store, and keeps image + marker" {
  run "${HOST_TEARDOWN}"
  assert_success
  run cat "${UMOUNT_LOG}"
  assert_line --index 0 "${L4T_EXPORT_DIR}"
  assert_line --index 1 "${STORE_DATA}"
  [[ -f "${STORE_IMG}" ]]
  [[ -f "${STORE_MARKER}" ]]
}

@test "host_teardown removes the empty /srv/jetson_l4t directory after unmounting" {
  run "${HOST_TEARDOWN}"
  assert_success
  [[ ! -e "${L4T_EXPORT_DIR}" ]]
  run cat "${RMDIR_LOG}"
  assert_output --partial "${L4T_EXPORT_DIR}"
}

@test "host_teardown leaves a non-empty /srv/jetson_l4t alone" {
  touch "${L4T_EXPORT_DIR}/someone-elses-file"
  run "${HOST_TEARDOWN}"
  assert_success
  [[ -d "${L4T_EXPORT_DIR}" ]]
  [[ ! -s "${RMDIR_LOG}" ]]
}

@test "host_teardown skips the store unmount when data/jetson_l4t is not mounted" {
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *data/jetson_l4t* ]] && exit 1
exit 0
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  run "${HOST_TEARDOWN}"
  assert_success
  run cat "${UMOUNT_LOG}"
  assert_output "${L4T_EXPORT_DIR}"   # only /srv
}

@test "host_teardown leaves an unmarked data/jetson_l4t mount alone (not ours to unmount)" {
  rm -f "${STORE_MARKER}"
  run "${HOST_TEARDOWN}"
  assert_success
  assert_output --partial 'no data/.l4t_store marker'
  run cat "${UMOUNT_LOG}"
  assert_output "${L4T_EXPORT_DIR}"   # only /srv
}

# ── host NFS export (#101) ───────────────────────────────────────────

# exportfs in the lib's test mode (NFS_EXPORT_TEST_ROOT=<tmpdir> →
# <tmpdir>/bin/exportfs, no sudo; export dir <tmpdir>/srv/jetson_l4t =
# L4T_EXPORT_DIR; export table <tmpdir>/etab). EXPORTFS_FAIL="-f:1" makes
# the flush fail.
_stub_exportfs() {
  EXPORTFS_LOG="${BATS_TEST_TMPDIR}/exportfs.log"; export EXPORTFS_LOG
  export NFS_EXPORT_TEST_ROOT="${BATS_TEST_TMPDIR}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/exportfs" <<'EOF'
#!/usr/bin/env bash
printf 'exportfs %s\n' "$*" >>"${EXPORTFS_LOG}"
[[ "${EXPORTFS_FAIL:-}" == "${1}:1" ]] && { echo 'exportfs: simulated failure' >&2; exit 1; }
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/exportfs"
}
REL="JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"

@test "host_teardown unexports the L4T tree from the host NFS server BEFORE unmounting /srv" {
  _stub_exportfs
  mkdir -p "${STORE_DATA}/${REL}"
  : >"${STORE_DATA}/${REL}/.prepared.yaml"
  run "${HOST_TEARDOWN}"
  assert_success
  # The kernel nfsd pins an exported directory: unexport first, or the
  # bridge umount fails with "target is busy".
  assert_output --partial 'unexported'
  [[ "${output#*unexported}" == *"Unmounting the NFS export bridge"* ]]
  run cat "${EXPORTFS_LOG}"
  assert_line --index 0 "exportfs -u [fc00:1:1::/48]:${L4T_EXPORT_DIR}/${REL}/rootfs"
  assert_line --index 1 "exportfs -u [fc00:1:1::/48]:${L4T_EXPORT_DIR}/${REL}/tools/kernel_flash/images"
  assert_line --index 2 "exportfs -u [fc00:1:1::/48]:${L4T_EXPORT_DIR}/${REL}/tools/kernel_flash/tmp"
  assert_line --index 3 'exportfs -f'
  [[ "${#lines[@]}" -eq 4 ]]
}

@test "host_teardown also unexports what the export table still lists under /srv/jetson_l4t when the marker is gone (clean.sh l4t first)" {
  _stub_exportfs
  # No .prepared.yaml anywhere, but etab still has the exports (real format:
  # tab separated, bare client).
  printf '%s/%s/rootfs\tfc00:1:1::/48(rw,async,no_root_squash)\n' "${L4T_EXPORT_DIR}" "${REL}" >"${BATS_TEST_TMPDIR}/etab"
  printf '%s/%s/tools/kernel_flash/images\tfc00:1:1::/48(rw,async,no_root_squash)\n' "${L4T_EXPORT_DIR}" "${REL}" >>"${BATS_TEST_TMPDIR}/etab"
  printf '/home/someone/share\t*(ro)\n' >>"${BATS_TEST_TMPDIR}/etab"
  run "${HOST_TEARDOWN}"
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line "exportfs -u [fc00:1:1::/48]:${L4T_EXPORT_DIR}/${REL}/rootfs"
  assert_line "exportfs -u [fc00:1:1::/48]:${L4T_EXPORT_DIR}/${REL}/tools/kernel_flash/images"
  refute_output --partial '/home/someone/share'   # not ours
  assert_line --index 2 'exportfs -f'
}

@test "host_teardown warns, still unmounts, and exits non-zero when the export flush fails" {
  _stub_exportfs
  mkdir -p "${STORE_DATA}/${REL}"
  : >"${STORE_DATA}/${REL}/.prepared.yaml"
  EXPORTFS_FAIL='-f:1' run "${HOST_TEARDOWN}"
  assert_failure
  assert_output --partial 'exportfs -f failed'
  assert_output --partial 'Unmounting the NFS export bridge'
  run cat "${UMOUNT_LOG}"
  assert_line --index 0 "${L4T_EXPORT_DIR}"
}

