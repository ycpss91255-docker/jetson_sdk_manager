#!/usr/bin/env bats
#
# Integration tests for prepare.sh / flash.sh storage-mode dispatch.
#
# Strategy: stand up a fake Linux_for_Tegra directory containing a
# mock `tools/kernel_flash/l4t_initrd_flash.sh` that records its argv
# to a tmp file, then drive prepare.sh / flash.sh via a stub jetson.yaml
# and assert the dispatched argv. Everything else (downloads, BSP
# extraction, apply_binaries, user creation, USB probe) is short-
# circuited via the volume marker file so the test only exercises the
# command-shape branch.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install \
      "${BATS_TEST_DIRNAME}/../../script"; do
    if [[ -f "${candidate}/prepare.sh" && -f "${candidate}/flash.sh" ]]; then
      SCRIPT_DIR="${candidate}"
      LIB_DIR="${candidate}/lib"
      break
    fi
  done
  if [[ -z "${SCRIPT_DIR:-}" ]]; then
    skip "prepare.sh / flash.sh not present in this image (devel-test runs in lint-only mode)"
  fi

  command -v yq >/dev/null 2>&1 || skip "yq not on PATH"

  # Stub jetson.yaml — caller overwrites storage block per test.
  JETSON_YAML="${BATS_TEST_TMPDIR}/jetson.yaml"
  export JETSON_YAML

  L4T_MAPPING_YAML="${BATS_TEST_TMPDIR}/_l4t_mapping.yaml"
  cat >"${L4T_MAPPING_YAML}" <<'EOF'
jetpack_to_l4t:
  "6.2.2":
    l4t_release: R36.5.0
    l4t_archive_tag: r36_release_v5.0
    bsp_url: http://example.invalid/bsp.tbz2
    rootfs_url: http://example.invalid/rootfs.tbz2
board_alias_to_target:
  agx-orin: jetson-agx-orin-devkit
  orin-nano: jetson-orin-nano-devkit-super
storage_alias_to_device:
  emmc: internal
  nvme: nvme0n1p1
  usb: sda1
EOF
  export L4T_MAPPING_YAML

  # Fake L4T tree + mock l4t_initrd_flash.sh that records argv.
  L4T_ROOT="${BATS_TEST_TMPDIR}/l4t"
  L4T_DIR="${L4T_ROOT}/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T_DIR}/tools/kernel_flash"
  ARGV_LOG="${BATS_TEST_TMPDIR}/argv.log"
  cat >"${L4T_DIR}/tools/kernel_flash/l4t_initrd_flash.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${ARGV_LOG}"
EOF
  chmod +x "${L4T_DIR}/tools/kernel_flash/l4t_initrd_flash.sh"
  export L4T_ROOT

  # Pre-populate the volume marker so prepare.sh skips the BSP / rootfs
  # / apply_binaries / user-create steps and goes straight to step 10
  # (the only step under test).
  cat >"${L4T_DIR}/.prepared.yaml" <<'EOF'
jetpack_version: "6.2.2"
hw_targets: "jetson-agx-orin-devkit"
phases: [bsp, rootfs, binaries, user]
EOF

  # Allow prepare.sh on tmpfs (BATS_TEST_TMPDIR may be tmpfs which the
  # guard treats as "unknown — proceed", but also defang fuseblk hosts).
  export JETSON_ALLOW_NON_UNIX_FS=1

  # Pre-seed BSP / rootfs tarballs so download_if_missing short-circuits
  # without hitting the network.
  DOWNLOADS_DIR="${BATS_TEST_TMPDIR}/downloads"
  mkdir -p "${DOWNLOADS_DIR}"
  printf 'stub bsp\n'    >"${DOWNLOADS_DIR}/bsp.tbz2"
  printf 'stub rootfs\n' >"${DOWNLOADS_DIR}/rootfs.tbz2"
  export DOWNLOADS_DIR

  # Stub `sudo` with a noop pass-through and a fake lsusb that always
  # claims an Orin in recovery is present (for flash.sh probe step).
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
# Pass through everything after stripping any leading flags / VAR=val pairs.
while [[ "$1" == -* || "$1" == *=* ]]; do shift; done
exec "$@"
EOF
  chmod +x "${STUB_BIN}/sudo"
  cat >"${STUB_BIN}/lsusb" <<'EOF'
#!/usr/bin/env bash
printf 'Bus 001 Device 002: ID 0955:7023 NVIDIA Corp. APX\n'
EOF
  chmod +x "${STUB_BIN}/lsusb"
  export PATH="${STUB_BIN}:${PATH}"

  # flash.sh's NFS preflight reads /proc/filesystems; point it at a fixture
  # that advertises nfsd so the dispatch tests reach the flash step. Tests
  # that exercise the negative branch override this.
  NFS_PROC_FILESYSTEMS="${BATS_TEST_TMPDIR}/filesystems"
  printf 'nodev\tnfsd\n' >"${NFS_PROC_FILESYSTEMS}"
  export NFS_PROC_FILESYSTEMS
}

_write_jetson_yaml() {
  local storage_block="$1"
  cat >"${JETSON_YAML}" <<EOF
jetpack:
  version: "6.2.2"
hardware:
  board: agx-orin
${storage_block}
user:
  username: jetson
  password: jetson
  hostname: jetson-agx
EOF
}

@test "prepare dispatches internal command shape for emmc alias" {
  _write_jetson_yaml "storage:
  device: emmc"
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  run cat "${ARGV_LOG}"
  assert_output --partial '--no-flash'
  assert_output --partial 'jetson-agx-orin-devkit'
  assert_output --partial 'internal'
  refute_output --partial '--external-only'
  refute_output --partial '--external-device'
  refute_output --partial 'flash_l4t_external.xml'
}

@test "prepare dispatches external command shape for nvme alias" {
  _write_jetson_yaml "storage:
  device: nvme"
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  run cat "${ARGV_LOG}"
  assert_output --partial '--no-flash'
  assert_output --partial '--external-only'
  assert_output --partial '--external-device'
  assert_output --partial 'nvme0n1p1'
  assert_output --partial 'flash_l4t_external.xml'
  # Exact-line match: 'external' is the positional mode arg, not a substring
  # of some flag — guards against a regression that drops the positional.
  run grep -Fxq external "${ARGV_LOG}"
  assert_success
}

@test "prepare honors device_path override on usb alias" {
  _write_jetson_yaml "storage:
  device: usb
  device_path: sdb1"
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  run cat "${ARGV_LOG}"
  assert_output --partial 'sdb1'
  refute_output --partial 'sda1'
}

@test "prepare rejects device_path on emmc alias" {
  _write_jetson_yaml "storage:
  device: emmc
  device_path: sdb1"
  # Merge stderr into stdout — emit_error writes the action message to
  # stderr and bats `run` only captures stdout by default.
  run bash -c "'${SCRIPT_DIR}/prepare.sh' 2>&1"
  assert_failure
  assert_output --partial 'internal mode'
  run cat "${ARGV_LOG}"
  refute_output --partial '--no-flash'
}

@test "flash dispatches internal command shape for emmc alias" {
  _write_jetson_yaml "storage:
  device: emmc"
  # Mark images phase done so flash.sh proceeds past the volume probe.
  yq -i '.phases |= (. + ["images"] | unique)' \
    "${L4T_DIR}/.prepared.yaml"
  run "${SCRIPT_DIR}/flash.sh"
  assert_success
  run cat "${ARGV_LOG}"
  assert_output --partial '--flash-only'
  assert_output --partial 'jetson-agx-orin-devkit'
  assert_output --partial 'internal'
  refute_output --partial '--external-device'
}

@test "flash dispatches external command shape for nvme alias" {
  _write_jetson_yaml "storage:
  device: nvme"
  yq -i '.phases |= (. + ["images"] | unique)' \
    "${L4T_DIR}/.prepared.yaml"
  run "${SCRIPT_DIR}/flash.sh"
  assert_success
  run cat "${ARGV_LOG}"
  assert_output --partial '--flash-only'
  assert_output --partial '--external-device'
  assert_output --partial 'nvme0n1p1'
  run grep -Fxq external "${ARGV_LOG}"
  assert_success
}

@test "flash aborts when the volume is empty (no marker)" {
  _write_jetson_yaml "storage:
  device: emmc"
  rm -f "${L4T_DIR}/.prepared.yaml"
  run bash -c "'${SCRIPT_DIR}/flash.sh' 2>&1"
  assert_failure
  assert_output --partial 'prepare'
  run cat "${ARGV_LOG}"
  refute_output --partial '--flash-only'
}

@test "flash aborts when BSP is prepared but images were not generated" {
  _write_jetson_yaml "storage:
  device: emmc"
  # The default marker has phases up to 'user' but no 'images' — exactly
  # the state left by `clean.sh build`. flash must refuse, not write.
  run bash -c "'${SCRIPT_DIR}/flash.sh' 2>&1"
  assert_failure
  assert_output --partial 'no flash images'
  run cat "${ARGV_LOG}"
  refute_output --partial '--flash-only'
}

@test "flash aborts when no Jetson is in recovery" {
  _write_jetson_yaml "storage:
  device: emmc"
  yq -i '.phases |= (. + ["images"] | unique)' "${L4T_DIR}/.prepared.yaml"
  # Override the always-on-recovery lsusb stub with one that reports an
  # empty bus for every recovery PID query.
  cat >"${STUB_BIN}/lsusb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB_BIN}/lsusb"
  run bash -c "'${SCRIPT_DIR}/flash.sh' 2>&1"
  assert_failure
  assert_output --partial 'recovery'
  run cat "${ARGV_LOG}"
  refute_output --partial '--flash-only'
}

@test "flash aborts with modprobe guidance when host nfsd is not loaded" {
  _write_jetson_yaml "storage:
  device: emmc"
  yq -i '.phases |= (. + ["images"] | unique)' "${L4T_DIR}/.prepared.yaml"
  # Recovery device is present (default stub); the only failing precondition
  # is the missing nfsd kernel module.
  printf 'nodev\ttmpfs\next4\n' >"${NFS_PROC_FILESYSTEMS}"   # no nfsd line
  run bash -c "'${SCRIPT_DIR}/flash.sh' 2>&1"
  assert_failure
  assert_output --partial 'modprobe nfsd'
  run cat "${ARGV_LOG}"
  refute_output --partial '--flash-only'
}

@test "flash aborts when storage mode differs from what was prepared" {
  _write_jetson_yaml "storage:
  device: nvme"
  # Marker says the volume was prepared for internal mode, images present.
  cat >"${L4T_DIR}/.prepared.yaml" <<'EOF'
jetpack_version: "6.2.2"
hw_targets: "jetson-agx-orin-devkit"
storage_mode: "internal"
phases: [bsp, rootfs, binaries, user, images]
EOF
  run bash -c "'${SCRIPT_DIR}/flash.sh' 2>&1"
  assert_failure
  assert_output --partial 'storage mode'
  run cat "${ARGV_LOG}"
  refute_output --partial '--flash-only'
}

@test "prepare records the resolved storage mode in the marker" {
  _write_jetson_yaml "storage:
  device: nvme"
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  run yq -r '.storage_mode' "${L4T_DIR}/.prepared.yaml"
  assert_output 'external'
}

@test "prepare regenerates images when the storage mode changed" {
  # Prepared for internal with images already done; jetson.yaml now external.
  cat >"${L4T_DIR}/.prepared.yaml" <<'EOF'
jetpack_version: "6.2.2"
hw_targets: "jetson-agx-orin-devkit"
storage_mode: "internal"
phases: [bsp, rootfs, binaries, user, images]
EOF
  _write_jetson_yaml "storage:
  device: nvme"
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  # images phase was dropped and regenerated under the external dispatch...
  run cat "${ARGV_LOG}"
  assert_output --partial '--external-only'
  # ...and the marker now records the new mode.
  run yq -r '.storage_mode' "${L4T_DIR}/.prepared.yaml"
  assert_output 'external'
}

@test "prepare dispatches the orin-nano target (non-agx board)" {
  local nano_dir="${L4T_ROOT}/JetPack_6.2.2_Linux_jetson-orin-nano-devkit-super/Linux_for_Tegra"
  mkdir -p "${nano_dir}/tools/kernel_flash"
  cat >"${nano_dir}/tools/kernel_flash/l4t_initrd_flash.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${ARGV_LOG}"
EOF
  chmod +x "${nano_dir}/tools/kernel_flash/l4t_initrd_flash.sh"
  cat >"${nano_dir}/.prepared.yaml" <<'EOF'
jetpack_version: "6.2.2"
hw_targets: "jetson-orin-nano-devkit-super"
phases: [bsp, rootfs, binaries, user]
EOF
  cat >"${JETSON_YAML}" <<'EOF'
jetpack:
  version: "6.2.2"
hardware:
  board: orin-nano
storage:
  device: nvme
user:
  username: jetson
  password: jetson
  hostname: jetson-nano
EOF
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  run cat "${ARGV_LOG}"
  assert_output --partial 'jetson-orin-nano-devkit-super'
  assert_output --partial 'nvme0n1p1'
}

@test "prepare writes a static NetworkManager profile when network.method=static" {
  cat >"${JETSON_YAML}" <<'EOF'
jetpack:
  version: "6.2.2"
hardware:
  board: agx-orin
storage:
  device: emmc
user:
  username: jetson
  password: jetson
  hostname: jetson-agx
network:
  method: static
  static:
    address: 192.168.1.50/24
    gateway: 192.168.1.1
    dns:
      - 8.8.8.8
      - 1.1.1.1
EOF
  run "${SCRIPT_DIR}/prepare.sh"
  assert_success
  local profile="${L4T_DIR}/rootfs/etc/NetworkManager/system-connections/jetson-static.nmconnection"
  assert_file_exists "${profile}"
  run cat "${profile}"
  assert_output --partial 'addresses=192.168.1.50/24'
  assert_output --partial 'gateway=192.168.1.1'
  assert_output --partial 'dns=8.8.8.8;1.1.1.1;'
}
