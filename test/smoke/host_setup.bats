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
  # Store step (#93): point the repo root at the tmpdir so data/ lands there,
  # and stub the tools it drives. STAT_BIN is a separate stub (not on PATH) so
  # the real stat keeps serving store_same_inode.
  export L4T_REPO_ROOT="${BATS_TEST_TMPDIR}"
  MKFS_LOG="${BATS_TEST_TMPDIR}/mkfs.log"; export MKFS_LOG
  CHOWN_LOG="${BATS_TEST_TMPDIR}/chown.log"; export CHOWN_LOG
  cat >"${STUB_BIN}/mkfs.ext4" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MKFS_LOG}"
EOF
  cat >"${STUB_BIN}/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CHOWN_LOG}"
EOF
  # losetup: `-j <image>` lists the loop device backing <image>; LOSETUP_DEV
  # controls the answer (empty = no device is backed by that image).
  cat >"${STUB_BIN}/losetup" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-j" && -n "${LOSETUP_DEV:-}" ]]; then
  printf '%s: []: (%s)\n' "${LOSETUP_DEV}" "$2"
fi
exit 0
EOF
  # findmnt: STORE_MNT_SOURCE is what data/jetson_l4t is mounted from.
  cat >"${STUB_BIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STORE_MNT_SOURCE:-/dev/loop0}"
EOF
  chmod +x "${STUB_BIN}"/*
  # fstype probe: STAT_FSTYPE decides what the checkout "is on" (default ext4).
  STAT_STUB="${BATS_TEST_TMPDIR}/stat-stub"
  cat >"${STAT_STUB}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STAT_FSTYPE:-ext4}"
EOF
  chmod +x "${STAT_STUB}"
  export STAT_BIN="${STAT_STUB}"

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
  # /srv is a mountpoint; data/jetson_l4t is not (native checkout).
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *srv/jetson_l4t* ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  # A real bind root shares device+inode with its source; model that with a
  # symlink so the identity check sees the same directory.
  mkdir -p "${L4T_EXPORT_SRC}" "$(dirname "${L4T_EXPORT_DIR}")"
  ln -s "${L4T_EXPORT_SRC}" "${L4T_EXPORT_DIR}"
  run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'already bind-mounted'
  [[ ! -s "${MOUNT_LOG}" ]]   # mount never called
}

@test "host_setup accepts an existing /srv bind whose findmnt SOURCE is a loop root (#93)" {
  # /srv is a mountpoint; data/jetson_l4t is not (native checkout).
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *srv/jetson_l4t* ]] && exit 0
exit 1
EOF
  cat >"${STUB_BIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/dev/loop0\n'
EOF
  chmod +x "${STUB_BIN}/mountpoint" "${STUB_BIN}/findmnt"
  mkdir -p "${L4T_EXPORT_SRC}" "$(dirname "${L4T_EXPORT_DIR}")"
  ln -s "${L4T_EXPORT_SRC}" "${L4T_EXPORT_DIR}"
  run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'already bind-mounted from this repo'
  [[ ! -s "${MOUNT_LOG}" ]]
}

@test "host_setup aborts when /srv is a mountpoint of something that is not this store (#93)" {
  # /srv is a mountpoint; data/jetson_l4t is not (native checkout).
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *srv/jetson_l4t* ]] && exit 0
exit 1
EOF
  cat >"${STUB_BIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/dev/loop7\n'
EOF
  chmod +x "${STUB_BIN}/mountpoint" "${STUB_BIN}/findmnt"
  mkdir -p "${L4T_EXPORT_SRC}" "${L4T_EXPORT_DIR}"   # two distinct directories
  run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'different source'
  assert_output --partial '/dev/loop7'
  [[ ! -s "${MOUNT_LOG}" ]]
}

@test "host_setup reuses the bind when /srv already points at this repo (#76)" {
  mkdir -p "${L4T_EXPORT_SRC}"
  # /srv is a mountpoint; data/jetson_l4t is not (native checkout).
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *srv/jetson_l4t* ]] && exit 0
exit 1
EOF
  cat >"${STUB_BIN}/findmnt" <<EOF
#!/usr/bin/env bash
printf '/dev/nvme0n1p5[%s]\n' "${L4T_EXPORT_SRC}"
EOF
  chmod +x "${STUB_BIN}/mountpoint" "${STUB_BIN}/findmnt"
  run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'already bind-mounted from this repo'
  [[ ! -s "${MOUNT_LOG}" ]]   # mount never called
}

@test "host_setup aborts when /srv is bind-mounted from a different repo (#76)" {
  # /srv is a mountpoint; data/jetson_l4t is not (native checkout).
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *srv/jetson_l4t* ]] && exit 0
exit 1
EOF
  cat >"${STUB_BIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/dev/nvme0n1p5[/tmp/other-clone/data/jetson_l4t]\n'
EOF
  chmod +x "${STUB_BIN}/mountpoint" "${STUB_BIN}/findmnt"
  run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'different source'
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

# ── step 0: L4T data store (#93) ─────────────────────────────────────

@test "host_setup on a native checkout provisions nothing and writes no marker" {
  run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'native'
  [[ ! -e "${BATS_TEST_TMPDIR}/data/jetson_l4t.img" ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/data/.l4t_store" ]]
  [[ ! -s "${MKFS_LOG}" ]]
}

@test "host_setup on a fuseblk checkout creates, formats and loop-mounts an in-repo ext4 image" {
  STAT_FSTYPE=fuseblk L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_success
  local img="${BATS_TEST_TMPDIR}/data/jetson_l4t.img"
  [[ -f "${img}" ]]
  [[ "$(stat -c %s "${img}")" -eq 268435456 ]]          # sparse, 256M logical
  run cat "${MKFS_LOG}"
  assert_output --partial '-m 0'
  assert_output --partial "${img}"
  run cat "${MOUNT_LOG}"
  assert_line --index 0 --partial "-o loop ${img} ${BATS_TEST_TMPDIR}/data/jetson_l4t"
  assert_line --index 1 --partial "--bind"                # /srv bridge comes AFTER the store
  run cat "${CHOWN_LOG}"
  assert_output --partial "${BATS_TEST_TMPDIR}/data/jetson_l4t"
  run cat "${BATS_TEST_TMPDIR}/data/.l4t_store"
  assert_line 'version=1'
  assert_line 'backend=loop-image'
  assert_line "image=${img}"
}

@test "host_setup re-run with a marker + mounted store neither re-formats nor re-mounts" {
  STAT_FSTYPE=fuseblk L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_success
  : >"${MKFS_LOG}"; : >"${MOUNT_LOG}"
  # The store is still mounted from the first run; /srv is not (fresh bridge).
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *data/jetson_l4t* ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  LOSETUP_DEV=/dev/loop0 STORE_MNT_SOURCE=/dev/loop0 \
    STAT_FSTYPE=fuseblk L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'already mounted'
  [[ ! -s "${MKFS_LOG}" ]]
  run cat "${MOUNT_LOG}"
  refute_output --partial '-o loop'
  assert_output --partial '--bind'
}

@test "host_setup refuses a data/jetson_l4t mounted from something other than its image" {
  STAT_FSTYPE=fuseblk L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_success
  : >"${MOUNT_LOG}"
  cp "${BATS_TEST_TMPDIR}/data/.l4t_store" "${BATS_TEST_TMPDIR}/marker.before"
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *data/jetson_l4t* ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  # Mounted from /dev/loop7, but no loop device is backed by OUR image.
  LOSETUP_DEV= STORE_MNT_SOURCE=/dev/loop7 \
    STAT_FSTYPE=fuseblk L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'not backed by'
  [[ ! -s "${MOUNT_LOG}" ]]                                   # no /srv bridge onto foreign data
  cmp -s "${BATS_TEST_TMPDIR}/data/.l4t_store" "${BATS_TEST_TMPDIR}/marker.before"   # marker untouched
}

@test "host_setup with L4T_STORE_DIR refuses a data/jetson_l4t mounted from another directory" {
  local store="${BATS_TEST_TMPDIR}/elsewhere/store"
  mkdir -p "${store}"
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *data/jetson_l4t* ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  # data/jetson_l4t (a real, distinct dir) is "mounted" but is not ${store}.
  L4T_STORE_DIR="${store}" run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'not backed by'
  [[ ! -e "${BATS_TEST_TMPDIR}/data/.l4t_store" ]]
}

@test "host_setup recovers a missing marker when the image already exists (crash window)" {
  STAT_FSTYPE=fuseblk L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_success
  rm -f "${BATS_TEST_TMPDIR}/data/.l4t_store"
  : >"${MKFS_LOG}"
  # Checkout now reads as ext4 (the loop mount is up), which used to mean "native".
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *data/jetson_l4t* ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  LOSETUP_DEV=/dev/loop0 STORE_MNT_SOURCE=/dev/loop0 \
    STAT_FSTYPE=ext4 L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'recover'
  [[ ! -s "${MKFS_LOG}" ]]
  run cat "${BATS_TEST_TMPDIR}/data/.l4t_store"
  assert_line 'backend=loop-image'
}

@test "host_setup fails closed on an unmarked data/jetson_l4t that is a mountpoint of unknown origin" {
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *data/jetson_l4t* ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}/mountpoint"
  STORE_MNT_SOURCE=/dev/nvme0n1p5[/var/lib/jetson_l4t] run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'unknown origin'
  assert_output --partial 'L4T_STORE_DIR'
  [[ ! -s "${MOUNT_LOG}" ]]
}

@test "host_setup aborts before touching anything when mkfs.ext4 is missing" {
  rm -f "${STUB_BIN}/mkfs.ext4"
  STAT_FSTYPE=fuseblk PATH="${STUB_BIN}:/usr/bin:/bin" run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'mkfs.ext4'
  assert_output --partial 'e2fsprogs'
  [[ ! -e "${BATS_TEST_TMPDIR}/data/jetson_l4t.img" ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/data/.l4t_store" ]]
}

@test "host_setup with L4T_STORE_DIR bind-mounts that directory and records directory-bind" {
  local store="${BATS_TEST_TMPDIR}/elsewhere/store"
  L4T_STORE_DIR="${store}" run "${HOST_SETUP}"
  assert_success
  [[ -d "${store}" ]]
  run cat "${MOUNT_LOG}"
  assert_line --index 0 --partial "--bind ${store} ${BATS_TEST_TMPDIR}/data/jetson_l4t"
  [[ ! -s "${MKFS_LOG}" ]]
  run cat "${BATS_TEST_TMPDIR}/data/.l4t_store"
  assert_line 'backend=directory-bind'
  assert_line "store=${store}"
}

@test "host_setup rejects an L4T_STORE_DIR that is itself on a non-unix filesystem" {
  local store="${BATS_TEST_TMPDIR}/elsewhere/store"
  STAT_FSTYPE=fuseblk L4T_STORE_DIR="${store}" run "${HOST_SETUP}"
  assert_failure
  assert_output --partial 'fuseblk'
  [[ ! -s "${MOUNT_LOG}" ]]
}

@test "host_setup canonicalises a relative L4T_STORE_DIR before recording it" {
  mkdir -p "${BATS_TEST_TMPDIR}/cwd"
  cd "${BATS_TEST_TMPDIR}/cwd"
  L4T_STORE_DIR=rel/store run "${HOST_SETUP}"
  assert_success
  run cat "${BATS_TEST_TMPDIR}/data/.l4t_store"
  assert_line "store=${BATS_TEST_TMPDIR}/cwd/rel/store"
  run cat "${MOUNT_LOG}"
  assert_line --index 0 --partial "--bind ${BATS_TEST_TMPDIR}/cwd/rel/store "
}

# ── step 6: host NFS export (#101) ───────────────────────────────────

# exportfs stub on PATH (sudo passes through), logging argv.
_stub_exportfs() {
  EXPORTFS_LOG="${BATS_TEST_TMPDIR}/exportfs.log"; export EXPORTFS_LOG
  cat >"${STUB_BIN}/exportfs" <<'EOF'
#!/usr/bin/env bash
printf 'exportfs %s\n' "$*" >>"${EXPORTFS_LOG}"
EOF
  chmod +x "${STUB_BIN}/exportfs"
}

# A prepared tree under data/ plus the /srv bridge as a symlink (the bind is
# stubbed), so the HOST-namespace export paths exist. Echoes the host path.
_prepared_tree() {
  local rel="JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T_EXPORT_SRC}/${rel}/rootfs" "${L4T_EXPORT_SRC}/${rel}/tools/kernel_flash/images"
  printf 'jetpack_version: "6.2.2"\nphases: [bsp, rootfs, binaries, user, images]\n' >"${L4T_EXPORT_SRC}/${rel}/.prepared.yaml"
  mkdir -p "$(dirname "${L4T_EXPORT_DIR}")"
  ln -s "${L4T_EXPORT_SRC}" "${L4T_EXPORT_DIR}"
  printf '%s/%s' "${L4T_EXPORT_DIR}" "${rel}"
}

@test "host_setup exports the prepared L4T tree from the host NFS server after the /srv bridge (#101)" {
  _stub_exportfs
  local l4t
  l4t="$(_prepared_tree)"
  run "${HOST_SETUP}"
  assert_success
  # The bridge (step 5) comes before the export (step 6): the export paths
  # are the host-namespace ones the bridge provides.
  [[ "${output#*Bridging}" == *"exported to fc00:1:1::/48"* ]]
  run cat "${EXPORTFS_LOG}"
  assert_line --partial "exportfs -o rw,nohide,insecure,no_subtree_check,async,no_root_squash [fc00:1:1::/48]:${l4t}/rootfs"
  assert_line --partial "[fc00:1:1::/48]:${l4t}/tools/kernel_flash/images"
  assert_line --partial "[fc00:1:1::/48]:${l4t}/tools/kernel_flash/tmp"
  assert_line 'exportfs -f'
}

@test "host_setup skips the export, not fatally, when the tree is prepared but images/ is gone (clean.sh build, then ./jetson prepare)" {
  _stub_exportfs
  local l4t
  l4t="$(_prepared_tree)"
  rm -rf "${l4t}/tools/kernel_flash/images"
  run "${HOST_SETUP}"
  assert_success                      # ./jetson prepare runs this BEFORE rebuilding images
  assert_output --partial 'incomplete'
  refute_output --partial 'Error ['
  [[ ! -e "${EXPORTFS_LOG}" ]]
}

@test "host_setup says so and skips the export when no L4T tree is prepared yet" {
  _stub_exportfs
  run "${HOST_SETUP}"
  assert_success
  assert_output --partial 'not prepared'
  assert_output --partial 'flash'
  [[ ! -e "${EXPORTFS_LOG}" ]]
}
