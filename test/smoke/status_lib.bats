#!/usr/bin/env bats
#
# Unit tests for script/lib/status.sh — the checks behind `./jetson status`
# (#95). Each check is a pure function that reads overridable inputs and
# prints one line "<ok|warn|bad>\t<message>"; no root, no hardware.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install/lib \
      /lint/script_lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${candidate}/status.sh" ]]; then
      LIB_DIR="${candidate}"
      break
    fi
  done
  if [[ -z "${LIB_DIR:-}" ]]; then
    skip "script/lib/status.sh not present in this image"
  fi

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/usb.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/store.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/status.sh"

  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}/data/jetson_l4t" "${REPO}/config/jetson"
  export L4T_REPO_ROOT="${REPO}"

  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"; mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/lsusb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${LSUSB_OUT:-}"
EOF
  cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ -n "${MOUNTED:-}" ]] && exit 0
exit 1
EOF
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"

  USBCORE_PARAMS="${BATS_TEST_TMPDIR}/usbcore"; mkdir -p "${USBCORE_PARAMS}"; export USBCORE_PARAMS
  printf -- '-1\n' >"${USBCORE_PARAMS}/autosuspend"; printf '2048\n' >"${USBCORE_PARAMS}/usbfs_memory_mb"
  NFSD_SYSFS="${BATS_TEST_TMPDIR}/sys-module-nfsd"; export NFSD_SYSFS
}

_level() { cut -f1; }

# ── jetson (USB) ─────────────────────────────────────────────────────

@test "status_jetson: board in recovery → ok with the PID" {
  LSUSB_OUT='Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX' run status_jetson
  assert_output --partial $'ok\t'
  assert_output --partial '7023'
  assert_output --partial 'recovery'
}

@test "status_jetson: booted L4T board → warn telling the user to enter REC" {
  LSUSB_OUT='Bus 002 Device 009: ID 0955:7020 NVIDIA Corp. L4T (Linux for Tegra) running on Tegra' run status_jetson
  assert_output --partial $'warn\t'
  assert_output --partial 'REC'
}

@test "status_jetson: nothing on the bus → warn" {
  LSUSB_OUT='' run status_jetson
  assert_output --partial $'warn\t'
  assert_output --partial 'no Jetson'
}

@test "status_jetson: two NVIDIA devices → warn about flashing the wrong board" {
  LSUSB_OUT=$'Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX\nBus 002 Device 009: ID 0955:7020 NVIDIA Corp. L4T' run status_jetson
  assert_output --partial $'warn\t'
  assert_output --partial '2 NVIDIA devices'
}

# ── prepare phases ───────────────────────────────────────────────────

@test "status_prepare: all phases recorded → ok" {
  local tree="${REPO}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${tree}"
  printf 'jetpack_version: "6.2.2"\nphases:\n  - bsp\n  - rootfs\n  - binaries\n  - user\n  - network\n  - images\n' >"${tree}/.prepared.yaml"
  run status_prepare
  assert_output --partial $'ok\t'
  assert_output --partial 'images'
}

@test "status_prepare: partial phases → warn naming the missing ones" {
  local tree="${REPO}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${tree}"
  printf 'phases: [bsp, rootfs]\n' >"${tree}/.prepared.yaml"
  run status_prepare
  assert_output --partial $'warn\t'
  assert_output --partial 'images'
}

@test "status_prepare: no marker → warn 'run ./jetson prepare'" {
  run status_prepare
  assert_output --partial $'warn\t'
  assert_output --partial 'jetson prepare'
}

# ── store ────────────────────────────────────────────────────────────

@test "status_store: loop-image marker + mounted → ok" {
  : >"${REPO}/data/jetson_l4t.img"
  printf 'version=1\nbackend=loop-image\nrepo_id=x\nimage=%s\n' "${REPO}/data/jetson_l4t.img" >"${REPO}/data/.l4t_store"
  MOUNTED=1 run status_store
  assert_output --partial $'ok\t'
  assert_output --partial 'loop-image'
}

@test "status_store: loop-image marker but not mounted → bad 'run ./jetson prepare (host_setup)'" {
  : >"${REPO}/data/jetson_l4t.img"
  printf 'version=1\nbackend=loop-image\nrepo_id=x\nimage=%s\n' "${REPO}/data/jetson_l4t.img" >"${REPO}/data/.l4t_store"
  run status_store
  assert_output --partial $'bad\t'
  assert_output --partial 'not mounted'
}

@test "status_store: no marker on a native checkout → ok native" {
  STAT_BIN="${STUB_BIN}/stat-ext4"; printf '#!/usr/bin/env bash\necho ext4\n' >"${STAT_BIN}"; chmod +x "${STAT_BIN}"; export STAT_BIN
  run status_store
  assert_output --partial $'ok\t'
  assert_output --partial 'native'
}

@test "status_store: no marker on fuseblk → bad" {
  STAT_BIN="${STUB_BIN}/stat-ntfs"; printf '#!/usr/bin/env bash\necho fuseblk\n' >"${STAT_BIN}"; chmod +x "${STAT_BIN}"; export STAT_BIN
  run status_store
  assert_output --partial $'bad\t'
  assert_output --partial 'fuseblk'
}

# ── kernel ───────────────────────────────────────────────────────────

@test "status_kernel: nfsd loaded + USB params set → ok" {
  mkdir -p "${NFSD_SYSFS}"
  run status_kernel
  assert_output --partial $'ok\t'
}

@test "status_kernel: nfsd missing → bad; USB params at defaults → warn" {
  printf '2\n' >"${USBCORE_PARAMS}/autosuspend"; printf '16\n' >"${USBCORE_PARAMS}/usbfs_memory_mb"
  run status_kernel
  assert_output --partial $'bad\t'
  assert_output --partial 'nfsd'
  assert_output --partial $'warn\t'
  assert_output --partial 'autosuspend'
}

# ── config ───────────────────────────────────────────────────────────

@test "status_config: preset with the default password → ok preset line + warn password" {
  printf 'hardware:\n  board: agx-orin\nstorage:\n  device: emmc\nuser:\n  username: jetson\n  password: jetson\n' >"${REPO}/config/jetson/agx-orin-emmc.yaml"
  ln -s config/jetson/agx-orin-emmc.yaml "${REPO}/jetson.yaml"
  run status_config
  assert_output --partial $'ok\t'
  assert_output --partial 'agx-orin-emmc.yaml'
  assert_output --partial $'warn\t'
  assert_output --partial 'default password'
  refute_output --partial 'password: jetson'   # never echo the actual secret
}

@test "status_config: missing jetson.yaml → bad" {
  run status_config
  assert_output --partial $'bad\t'
  assert_output --partial 'jetson.yaml'
}

# ── review round 1 ───────────────────────────────────────────────────

@test "status_store: no marker and no data/jetson_l4t yet → reports, never creates the directory" {
  rmdir "${REPO}/data/jetson_l4t"
  STAT_BIN="${STUB_BIN}/stat-ext4"; printf '#!/usr/bin/env bash\necho ext4\n' >"${STAT_BIN}"; chmod +x "${STAT_BIN}"; export STAT_BIN
  run status_store
  assert_output --partial $'ok\t'
  assert_output --partial 'not created yet'
  [[ ! -e "${REPO}/data/jetson_l4t" ]]
}

@test "status_config: quoted values and inline comments are parsed; quoted default password still warns" {
  printf 'hardware:\n  board: "agx-orin"   # devkit\nstorage:\n  device: '"'"'emmc'"'"'\nuser:\n  password: "jetson"\n' >"${REPO}/jetson.yaml"
  run status_config
  assert_output --partial 'board agx-orin, storage emmc'
  assert_output --partial 'default password'
  refute_output --partial '"'
}

@test "status_config: unparsable board / storage → warn, not ok" {
  printf 'user:\n  password: x\n' >"${REPO}/jetson.yaml"
  run status_config
  assert_output --partial $'warn\t'
  assert_output --partial 'board'
  refute_output --partial $'ok\tconfig'
}

@test "status_prepare: quoted phases with inline comments count as done" {
  local tree="${REPO}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${tree}"
  printf 'phases:\n  - "bsp"\n  - rootfs # done\n  - '"'"'binaries'"'"'\n  - user\n  - network\n  - "images" # ok\n' >"${tree}/.prepared.yaml"
  run status_prepare
  assert_output --partial $'ok\t'
}

@test "status_prepare: two markers → warn about the ambiguity instead of picking one" {
  local a="${REPO}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  local b="${REPO}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-orin-nano-devkit-super/Linux_for_Tegra"
  mkdir -p "${a}" "${b}"; printf 'phases: [images]\n' >"${a}/.prepared.yaml"; printf 'phases: [bsp]\n' >"${b}/.prepared.yaml"
  run status_prepare
  assert_output --partial $'warn\t'
  assert_output --partial 'more than one'
}

@test "status_jetson: two boards in recovery → warn says so explicitly" {
  LSUSB_OUT=$'Bus 003 Device 049: ID 0955:7023 NVIDIA Corp. APX\nBus 001 Device 007: ID 0955:7523 NVIDIA Corp. APX' run status_jetson
  assert_output --partial '2 in recovery'
}

# ── #97 ─────────────────────────────────────────────────────────────

@test "status_prepare: wording no longer promises 'no board needed'" {
  run status_prepare
  refute_output --partial 'no board needed'
  assert_output --partial 'recovery'
}
