#!/usr/bin/env bats
#
# Unit tests for script/lib/nfs_export.sh — exporting the prepared L4T tree
# from the HOST NFS server (#101). `exportfs`, `sudo` (pass-through) and
# `pgrep` are stubbed on PATH; every path lives in a tmp dir. No root, no
# real kernel nfsd.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  for candidate in \
      /opt/jetson_install/lib \
      /lint/script_lib \
      "${BATS_TEST_DIRNAME}/../../script/lib"; do
    if [[ -f "${candidate}/nfs_export.sh" ]]; then
      LIB_DIR="${candidate}"
      break
    fi
  done
  if [[ -z "${LIB_DIR:-}" ]]; then
    skip "script/lib/nfs_export.sh not present in this image"
  fi

  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/nfs_export.sh"

  EXPORTFS_LOG="${BATS_TEST_TMPDIR}/exportfs.log"; export EXPORTFS_LOG
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"; mkdir -p "${STUB_BIN}"
  # sudo: strip leading flags, then exec the rest (pass-through).
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do shift; done
exec "$@"
EOF
  # exportfs: log argv; `-s` lists EXPORTED (one "path client(opts)" line
  # each); `-u` of something not exported fails like the real tool.
  cat >"${STUB_BIN}/exportfs" <<'EOF'
#!/usr/bin/env bash
printf 'exportfs %s\n' "$*" >>"${EXPORTFS_LOG}"
case "${1:-}" in
  -s) for p in ${EXPORTED:-}; do printf '%s\t[fc00:1:1::/48](rw,async)\n' "${p}"; done ;;
  -u) [[ " ${EXPORTED:-} " == *" ${2##*:} "* ]] \
        || { printf "exportfs: Could not find '%s' to unexport.\\n" "$2" >&2; exit 1; } ;;
esac
exit 0
EOF
  # pgrep: MOUNTD=1 means a host rpc.mountd is running.
  cat >"${STUB_BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *rpc.mountd* && -n "${MOUNTD:-}" ]] && { echo 4242; exit 0; }
exit 1
EOF
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"
  # No readable export table by default → status falls back to `exportfs -s`.
  export NFS_ETAB="${BATS_TEST_TMPDIR}/no-such-etab"

  # A prepared tree as the HOST sees it (the /srv bridge).
  L4T="${BATS_TEST_TMPDIR}/srv/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T}/rootfs" "${L4T}/tools/kernel_flash/images" "${L4T}/tools/kernel_flash/tmp"
  export L4T
}

# ── paths ────────────────────────────────────────────────────────────

@test "nfs_export_paths: rootfs, kernel_flash/images and kernel_flash/tmp, in that order" {
  run nfs_export_paths "${L4T}"
  assert_success
  assert_line --index 0 "${L4T}/rootfs"
  assert_line --index 1 "${L4T}/tools/kernel_flash/images"
  assert_line --index 2 "${L4T}/tools/kernel_flash/tmp"
  [[ "${#lines[@]}" -eq 3 ]]
}

# ── nfs_export_on ────────────────────────────────────────────────────

@test "nfs_export_on: per path unexport then export with NVIDIA's rw option string, then one flush" {
  run nfs_export_on "${L4T}"
  assert_success
  run cat "${EXPORTFS_LOG}"
  local opts='rw,nohide,insecure,no_subtree_check,async,no_root_squash'
  assert_line --index 0 "exportfs -u [fc00:1:1::/48]:${L4T}/rootfs"
  assert_line --index 1 "exportfs -o ${opts} [fc00:1:1::/48]:${L4T}/rootfs"
  assert_line --index 2 "exportfs -u [fc00:1:1::/48]:${L4T}/tools/kernel_flash/images"
  assert_line --index 3 "exportfs -o ${opts} [fc00:1:1::/48]:${L4T}/tools/kernel_flash/images"
  assert_line --index 4 "exportfs -u [fc00:1:1::/48]:${L4T}/tools/kernel_flash/tmp"
  assert_line --index 5 "exportfs -o ${opts} [fc00:1:1::/48]:${L4T}/tools/kernel_flash/tmp"
  assert_line --index 6 "exportfs -f"
  [[ "${#lines[@]}" -eq 7 ]]
}

@test "nfs_export_on: a failing unexport (not exported yet) does not stop the export" {
  # EXPORTED is empty → every `exportfs -u` exits 1 like the real tool.
  EXPORTED= run nfs_export_on "${L4T}"
  assert_success
  run grep -c '^exportfs -o' "${EXPORTFS_LOG}"
  assert_output 3
}

@test "nfs_export_on: re-run is idempotent (same u→o→f sequence again)" {
  nfs_export_on "${L4T}"
  : >"${EXPORTFS_LOG}"
  EXPORTED="${L4T}/rootfs ${L4T}/tools/kernel_flash/images ${L4T}/tools/kernel_flash/tmp" run nfs_export_on "${L4T}"
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line --index 0 --partial 'exportfs -u'
  assert_line --index 6 'exportfs -f'
}

@test "nfs_export_on: no exportfs on the host → says so and returns 0 without touching anything" {
  rm -f "${STUB_BIN}/exportfs"
  PATH="${STUB_BIN}:/usr/bin:/bin" run nfs_export_on "${L4T}"
  assert_success
  assert_output --partial 'exportfs'
  assert_output --partial 'container'
  [[ ! -e "${EXPORTFS_LOG}" ]]
}

@test "nfs_export_on: missing rootfs → emit_error host-config, exit 1, nothing exported" {
  rm -rf "${L4T}/rootfs"
  run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'Error [host-config]'
  assert_output --partial "${L4T}/rootfs"
  [[ ! -e "${EXPORTFS_LOG}" ]]
}

@test "nfs_export_on: missing kernel_flash/images → emit_error, nothing exported" {
  rm -rf "${L4T}/tools/kernel_flash/images"
  run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'Error [host-config]'
  assert_output --partial 'kernel_flash/images'
  [[ ! -e "${EXPORTFS_LOG}" ]]
}

@test "nfs_export_on: kernel_flash/tmp is NVIDIA's flash-time scratch dir — created when missing, not an error" {
  rm -rf "${L4T}/tools/kernel_flash/tmp"
  run nfs_export_on "${L4T}"
  assert_success
  [[ -d "${L4T}/tools/kernel_flash/tmp" ]]
  run grep -c '^exportfs -o' "${EXPORTFS_LOG}"
  assert_output 3
}

@test "nfs_export_on: honours NFS_EXPORT_CLIENT (an IPv4 client gets no brackets)" {
  NFS_EXPORT_CLIENT=192.168.55.0/24 run nfs_export_on "${L4T}"
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line --index 1 --partial " 192.168.55.0/24:${L4T}/rootfs"
  refute_output --partial '['
}

# ── nfs_export_off ───────────────────────────────────────────────────

@test "nfs_export_off: unexports the three paths, then flushes" {
  EXPORTED="${L4T}/rootfs ${L4T}/tools/kernel_flash/images ${L4T}/tools/kernel_flash/tmp" run nfs_export_off "${L4T}"
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line --index 0 "exportfs -u [fc00:1:1::/48]:${L4T}/rootfs"
  assert_line --index 1 "exportfs -u [fc00:1:1::/48]:${L4T}/tools/kernel_flash/images"
  assert_line --index 2 "exportfs -u [fc00:1:1::/48]:${L4T}/tools/kernel_flash/tmp"
  assert_line --index 3 "exportfs -f"
  [[ "${#lines[@]}" -eq 4 ]]
}

@test "nfs_export_off: 'not exported' is not an error (idempotent teardown)" {
  EXPORTED= run nfs_export_off "${L4T}"
  assert_success
  refute_output --partial 'Could not find'
  run cat "${EXPORTFS_LOG}"
  assert_line --index 3 "exportfs -f"
}

@test "nfs_export_off: no exportfs on the host → nothing to undo, returns 0" {
  rm -f "${STUB_BIN}/exportfs"
  PATH="${STUB_BIN}:/usr/bin:/bin" run nfs_export_off "${L4T}"
  assert_success
  [[ ! -e "${EXPORTFS_LOG}" ]]
}

@test "nfs_export_off: a missing tree is fine — the paths are unexported by name" {
  rm -rf "${L4T}"
  EXPORTED= run nfs_export_off "${L4T}"
  assert_success
  run grep -c '^exportfs -u' "${EXPORTFS_LOG}"
  assert_output 3
}

# ── nfs_host_mountd_running ──────────────────────────────────────────

@test "nfs_host_mountd_running: true iff pgrep finds rpc.mountd" {
  MOUNTD=1 run nfs_host_mountd_running
  assert_success
  MOUNTD= run nfs_host_mountd_running
  assert_failure
}

# ── nfs_export_status ────────────────────────────────────────────────

@test "nfs_export_status: no exportfs on the host → ok, the container serves NFS itself" {
  rm -f "${STUB_BIN}/exportfs"
  MOUNTD= PATH="${STUB_BIN}:/usr/bin:/bin" run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
  assert_output --partial 'container'
}

@test "nfs_export_status: host rpc.mountd running and all three exported → ok" {
  MOUNTD=1 EXPORTED="${L4T}/rootfs ${L4T}/tools/kernel_flash/images ${L4T}/tools/kernel_flash/tmp" run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
  assert_output --partial 'rpc.mountd'
  refute_output --partial $'warn\t'
}

@test "nfs_export_status: host rpc.mountd running but exports missing → warn naming the hang (#101)" {
  MOUNTD=1 EXPORTED="${L4T}/rootfs" run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'warn\t'
  assert_output --partial 'rpc.mountd'
  assert_output --partial 'kernel_flash/images'
  assert_output --partial 'hang'
}

@test "nfs_export_status: reads the export table (etab) when readable — exportfs -s needs root for its lock" {
  # etab lines are "<path>\t<client>(<opts>)"; exportfs -s is made to fail.
  printf '%s\t[fc00:1:1::/48](rw,async,no_root_squash)\n' \
    "${L4T}/rootfs" "${L4T}/tools/kernel_flash/images" "${L4T}/tools/kernel_flash/tmp" >"${BATS_TEST_TMPDIR}/etab"
  cat >"${STUB_BIN}/exportfs" <<'EOF'
#!/usr/bin/env bash
printf 'exportfs: could not open /var/lib/nfs/.etab.lock for locking: errno 13 (Permission denied)\n' >&2
exit 0
EOF
  chmod +x "${STUB_BIN}/exportfs"
  MOUNTD=1 NFS_ETAB="${BATS_TEST_TMPDIR}/etab" run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
  refute_output --partial $'warn\t'
  [[ ! -e "${EXPORTFS_LOG}" ]]   # never shelled out to exportfs
}

@test "nfs_export_status: exportfs installed but no rpc.mountd → ok (no competing mountd)" {
  MOUNTD= EXPORTED= run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
  refute_output --partial $'warn\t'
}

@test "nfs_export_status: host rpc.mountd running, tree not prepared yet → ok, tells who exports later" {
  MOUNTD=1 run nfs_export_status ""
  assert_success
  assert_output --partial $'ok\t'
  assert_output --partial 'flash'
}

# ── nfs_export_l4t_dir ───────────────────────────────────────────────

@test "nfs_export_l4t_dir: maps the single .prepared.yaml under data/jetson_l4t to the /srv bridge path" {
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  : >"${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra/.prepared.yaml"
  L4T_REPO_ROOT="${repo}" L4T_EXPORT_DIR=/srv/jetson_l4t run nfs_export_l4t_dir
  assert_success
  assert_output '/srv/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra'
}

@test "nfs_export_l4t_dir: no prepared tree → exit 1, empty; two trees → exit 2" {
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/data/jetson_l4t"
  L4T_REPO_ROOT="${repo}" run nfs_export_l4t_dir
  assert_failure 1
  assert_output ''
  mkdir -p "${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_a/Linux_for_Tegra" "${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_b/Linux_for_Tegra"
  : >"${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_a/Linux_for_Tegra/.prepared.yaml"
  : >"${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_b/Linux_for_Tegra/.prepared.yaml"
  L4T_REPO_ROOT="${repo}" run nfs_export_l4t_dir
  assert_failure 2
}
