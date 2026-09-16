#!/usr/bin/env bats
#
# Unit tests for script/lib/nfs_export.sh — exporting the prepared L4T tree
# from the HOST NFS server (#101).
#
# The lib has an explicit test mode: NFS_EXPORT_TEST_ROOT=<dir> makes it use
# <dir>/bin/exportfs, <dir>/etab and <dir>/srv/jetson_l4t, and run exportfs
# DIRECTLY (no sudo). Production ignores every such variable and only ever
# hands literal constants to sudo (review round 1). No root, no real nfsd.

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

  export NFS_EXPORT_TEST_ROOT="${BATS_TEST_TMPDIR}"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/errors.sh"
  # shellcheck disable=SC1091
  . "${LIB_DIR}/nfs_export.sh"

  EXPORTFS_LOG="${BATS_TEST_TMPDIR}/exportfs.log"; export EXPORTFS_LOG
  TEST_BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${TEST_BIN}"
  # exportfs (test-mode path): log argv; `-u` of something not in EXPORTED
  # fails like the real tool; EXPORTFS_FAIL="<flag>:<n>" makes the n-th call
  # with that flag fail (e.g. "-o:2"), EXPORTFS_FAIL="-f:1" the flush.
  cat >"${TEST_BIN}/exportfs" <<'EOF'
#!/usr/bin/env bash
printf 'exportfs %s\n' "$*" >>"${EXPORTFS_LOG}"
flag="${1:-}"
cnt="${EXPORTFS_LOG}.count${flag}"
n=$(( $(cat "${cnt}" 2>/dev/null || echo 0) + 1 )); printf '%s' "${n}" >"${cnt}"
if [[ -n "${EXPORTFS_FAIL:-}" && "${EXPORTFS_FAIL}" == "${flag}:${n}" ]]; then
  printf 'exportfs: simulated failure (%s #%s)\n' "${flag}" "${n}" >&2; exit 1
fi
if [[ "${flag}" == -u ]]; then
  [[ " ${EXPORTED:-} " == *" ${2##*:} "* ]] \
    || { printf "exportfs: Could not find '%s' to unexport.\\n" "$2" >&2; exit 1; }
fi
exit 0
EOF
  # pgrep (PATH, unprivileged): MOUNTD=1 means a host rpc.mountd is running.
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"; mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *rpc.mountd* && -n "${MOUNTD:-}" ]] && { echo 4242; exit 0; }
exit 1
EOF
  # sudo: must NEVER be reached in test mode; log + fail loudly if it is.
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${SUDO_LOG:-/dev/null}"
exit 99
EOF
  chmod +x "${TEST_BIN}"/* "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"
  SUDO_LOG="${BATS_TEST_TMPDIR}/sudo.log"; export SUDO_LOG

  # A prepared tree as the HOST sees it (the /srv bridge, test-mode root).
  L4T="${BATS_TEST_TMPDIR}/srv/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  mkdir -p "${L4T}/rootfs" "${L4T}/tools/kernel_flash/images" "${L4T}/tools/kernel_flash/tmp"
  export L4T
  ETAB="${BATS_TEST_TMPDIR}/etab"; export ETAB
}

# _etab <path>... — write a real-format export table (tab separated,
# client WITHOUT brackets, as nfs-utils writes it) with rw options.
_etab() {
  local p
  : >"${ETAB}"
  for p in "$@"; do
    printf '%s\tfc00:1:1::/48(rw,async,wdelay,nohide,insecure,no_root_squash,no_subtree_check,fsid=0,sec=sys,rw,insecure,no_root_squash,no_all_squash)\n' "${p}" >>"${ETAB}"
  done
}
_all_three() { _etab "${L4T}/rootfs" "${L4T}/tools/kernel_flash/images" "${L4T}/tools/kernel_flash/tmp"; }

# ── test mode / production constants ─────────────────────────────────

@test "test mode announces itself and points exportfs / etab / export dir under NFS_EXPORT_TEST_ROOT" {
  run bash -c ". '${LIB_DIR}/errors.sh'; . '${LIB_DIR}/nfs_export.sh'; nfs_exportfs_bin; nfs_etab; nfs_export_dir"
  assert_success
  assert_output --partial '[test mode]'
  assert_line "${BATS_TEST_TMPDIR}/bin/exportfs"
  assert_line "${BATS_TEST_TMPDIR}/etab"
  assert_line "${BATS_TEST_TMPDIR}/srv/jetson_l4t"
}

@test "production ignores EXPORTFS_BIN / NFS_ETAB / L4T_EXPORT_DIR / NFS_EXPORT_CLIENT / NFS_EXPORT_OPTS from the environment" {
  run env -u NFS_EXPORT_TEST_ROOT EXPORTFS_BIN=/tmp/evil NFS_ETAB=/tmp/etab L4T_EXPORT_DIR=/tmp/srv \
      NFS_EXPORT_CLIENT=0.0.0.0/0 NFS_EXPORT_OPTS=ro \
      bash -c ". '${LIB_DIR}/errors.sh'; . '${LIB_DIR}/nfs_export.sh'; nfs_exportfs_bin; nfs_etab; nfs_export_dir; nfs_export_spec /x; echo; echo \"\${NFS_EXPORT_OPTS}\""
  assert_success
  refute_output --partial '[test mode]'
  assert_line --index 0 '/usr/sbin/exportfs'
  assert_line --index 1 '/var/lib/nfs/etab'
  assert_line --index 2 '/srv/jetson_l4t'
  assert_line --index 3 '[fc00:1:1::/48]:/x'
  assert_line --index 4 'rw,nohide,insecure,no_subtree_check,async,no_root_squash'
}

@test "production: EXPORTFS_BIN=/tmp/x is never executed — only the literal /usr/sbin/exportfs goes to sudo" {
  # A would-be payload that records if it ever runs.
  local evil="${BATS_TEST_TMPDIR}/evil"
  printf '#!/usr/bin/env bash\ntouch "%s.ran"\n' "${evil}" >"${evil}"; chmod +x "${evil}"
  # sudo stub that records and runs nothing.
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${SUDO_LOG}"
exit 0
EOF
  chmod +x "${STUB_BIN}/sudo"
  # The production tree path must live under the literal /srv/jetson_l4t;
  # /srv/jetson_l4t/... is not writable here, so the rootfs check fires
  # first unless the real exportfs is absent (then it is a no-op before
  # any path check). Either way: nothing under sudo but the constant.
  run env -u NFS_EXPORT_TEST_ROOT EXPORTFS_BIN="${evil}" \
      bash -c ". '${LIB_DIR}/errors.sh'; . '${LIB_DIR}/nfs_export.sh'; nfs_export_on /srv/jetson_l4t/JetPack_x/Linux_for_Tegra"
  [[ ! -e "${evil}.ran" ]]
  if [[ -x /usr/sbin/exportfs ]]; then
    # real nfs-kernel-server in this image: the tree does not exist → emit_error, no sudo
    assert_failure
    assert_output --partial 'Error [host-config]'
  else
    assert_success
    assert_output --partial '/usr/sbin/exportfs'
    assert_output --partial 'not installed'
  fi
  if [[ -s "${SUDO_LOG}" ]]; then
    run grep -vc '^sudo /usr/sbin/exportfs' "${SUDO_LOG}"
    assert_output 0
  fi
}

@test "production: nfs_export_on refuses a tree outside /srv/jetson_l4t before touching sudo" {
  cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${SUDO_LOG}"
exit 0
EOF
  chmod +x "${STUB_BIN}/sudo"
  run env -u NFS_EXPORT_TEST_ROOT \
      bash -c ". '${LIB_DIR}/errors.sh'; . '${LIB_DIR}/nfs_export.sh'; nfs_export_on '${L4T}'"
  if [[ -x /usr/sbin/exportfs ]]; then
    assert_failure
    assert_output --partial '/srv/jetson_l4t'
  else
    assert_success   # no exportfs → no-op before any path check
  fi
  [[ ! -s "${SUDO_LOG}" ]]
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

@test "nfs_export_on: per path unexport then export with NVIDIA's rw option string, then one flush — no sudo in test mode" {
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
  [[ ! -s "${SUDO_LOG}" ]]
}

@test "nfs_export_on: a failing unexport (not exported yet) does not stop the export" {
  EXPORTED= run nfs_export_on "${L4T}"
  assert_success
  run grep -c '^exportfs -o' "${EXPORTFS_LOG}"
  assert_output 3
}

@test "nfs_export_on: re-run is idempotent (same u→o→f sequence again)" {
  nfs_export_on "${L4T}"
  rm -f "${EXPORTFS_LOG}" "${EXPORTFS_LOG}".count*
  EXPORTED="${L4T}/rootfs ${L4T}/tools/kernel_flash/images ${L4T}/tools/kernel_flash/tmp" run nfs_export_on "${L4T}"
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line --index 0 --partial 'exportfs -u'
  assert_line --index 6 'exportfs -f'
}

@test "nfs_export_on: no exportfs on the host → says so and returns 0 without touching anything" {
  rm -f "${TEST_BIN}/exportfs"
  run nfs_export_on "${L4T}"
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

@test "nfs_export_on: creating kernel_flash/tmp fails → emit_error, exit 1, nothing exported" {
  rm -rf "${L4T}/tools/kernel_flash/tmp"
  : >"${L4T}/tools/kernel_flash/tmp"     # a FILE in the way: mkdir -p fails even as root
  run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'Error [host-config]'
  assert_output --partial 'kernel_flash/tmp'
  [[ ! -e "${EXPORTFS_LOG}" ]]
}

@test "nfs_export_on: the 1st exportfs -o failing → the other two are still tried, the flush still runs, exit 1" {
  EXPORTFS_FAIL='-o:1' run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'Error [host-config]'
  assert_output --partial "${L4T}/rootfs"
  run cat "${EXPORTFS_LOG}"
  assert_line --index 3 --partial 'exportfs -o'
  assert_line --index 5 --partial 'exportfs -o'
  assert_line --index 6 'exportfs -f'
}

@test "nfs_export_on: the 2nd exportfs -o failing → flush still runs, exit 1, names images" {
  EXPORTFS_FAIL='-o:2' run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'kernel_flash/images'
  run tail -n1 "${EXPORTFS_LOG}"
  assert_output 'exportfs -f'
}

@test "nfs_export_on: the 3rd exportfs -o failing → flush still runs, exit 1, names tmp" {
  EXPORTFS_FAIL='-o:3' run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'kernel_flash/tmp'
  run tail -n1 "${EXPORTFS_LOG}"
  assert_output 'exportfs -f'
}

@test "nfs_export_on: the final exportfs -f failing → exit 1 with a stale-handle warning" {
  EXPORTFS_FAIL='-f:1' run nfs_export_on "${L4T}"
  assert_failure 1
  assert_output --partial 'exportfs -f'
  assert_output --partial 'stale'
}

# ── nfs_export_off / nfs_export_off_all ──────────────────────────────

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
  rm -f "${TEST_BIN}/exportfs"
  run nfs_export_off "${L4T}"
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

@test "nfs_export_off: the flush failing → exit 1" {
  EXPORTFS_FAIL='-f:1' run nfs_export_off "${L4T}"
  assert_failure 1
  assert_output --partial 'exportfs -f'
}

@test "nfs_export_off_all: also unexports every etab entry under the export dir, even with no marker (clean.sh l4t ran first)" {
  local other="${BATS_TEST_TMPDIR}/srv/jetson_l4t/JetPack_6.2.2_Linux_jetson-orin-nano-devkit-super/Linux_for_Tegra"
  _etab "${other}/rootfs" "${other}/tools/kernel_flash/images" "/home/someone/else"
  run nfs_export_off_all ""
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line "exportfs -u [fc00:1:1::/48]:${other}/rootfs"
  assert_line "exportfs -u [fc00:1:1::/48]:${other}/tools/kernel_flash/images"
  refute_output --partial '/home/someone/else'     # not ours
  assert_line --index 2 'exportfs -f'
  [[ "${#lines[@]}" -eq 3 ]]
}

@test "nfs_export_off_all: marker trees + etab entries, deduplicated, one flush" {
  _all_three
  run nfs_export_off_all "${L4T}"
  assert_success
  run grep -c '^exportfs -u' "${EXPORTFS_LOG}"
  assert_output 3
  run grep -c '^exportfs -f' "${EXPORTFS_LOG}"
  assert_output 1
}

@test "nfs_export_off_all: an etab entry with a space in the path is unexported intact" {
  local sp="${BATS_TEST_TMPDIR}/srv/jetson_l4t/JetPack_6.2.2_Linux_a b/Linux_for_Tegra/rootfs"
  _etab "${sp}"
  run nfs_export_off_all ""
  assert_success
  run cat "${EXPORTFS_LOG}"
  assert_line --index 0 "exportfs -u [fc00:1:1::/48]:${sp}"
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
  rm -f "${TEST_BIN}/exportfs"
  MOUNTD= run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
  assert_output --partial 'container'
}

@test "nfs_export_status: host rpc.mountd running and all three exported rw to the client → ok" {
  _all_three
  MOUNTD=1 run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
  assert_output --partial 'rpc.mountd'
  refute_output --partial $'warn\t'
  [[ ! -e "${EXPORTFS_LOG}" ]]   # read from etab, exportfs never run
}

@test "nfs_export_status: host rpc.mountd running but exports missing → warn naming the hang (#101)" {
  _etab "${L4T}/rootfs"
  MOUNTD=1 run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'warn\t'
  assert_output --partial 'rpc.mountd'
  assert_output --partial 'kernel_flash/images'
  assert_output --partial 'hang'
}

@test "nfs_export_status: right path but exported to another client → warn" {
  _all_three
  sed -i "s#^\(${L4T}/rootfs\t\)fc00:1:1::/48#\1192.168.55.0/24#" "${ETAB}"
  MOUNTD=1 run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'warn\t'
  assert_output --partial 'rootfs'
  assert_output --partial 'fc00:1:1::/48'
}

@test "nfs_export_status: right path and client but ro → warn (the board chroots into rootfs)" {
  _all_three
  sed -i "s#^\(${L4T}/rootfs\tfc00:1:1::/48\)(rw,#\1(ro,#; s#,rw,#,#" "${ETAB}"
  MOUNTD=1 run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'warn\t'
  assert_output --partial 'rootfs'
  assert_output --partial 'rw'
}

@test "nfs_export_status: etab is tab separated — a path with a space is matched whole" {
  local sp="${BATS_TEST_TMPDIR}/srv/jetson_l4t/JetPack_6.2.2_Linux_a b/Linux_for_Tegra"
  mkdir -p "${sp}"
  _etab "${sp}/rootfs" "${sp}/tools/kernel_flash/images" "${sp}/tools/kernel_flash/tmp"
  MOUNTD=1 run nfs_export_status "${sp}"
  assert_success
  assert_output --partial $'ok\t'
  refute_output --partial $'warn\t'
}

@test "nfs_export_status: a bracketed client in etab is normalised before comparing" {
  _all_three
  sed -i 's#\tfc00:1:1::/48(#\t[fc00:1:1::/48](#' "${ETAB}"
  MOUNTD=1 run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'ok\t'
}

@test "nfs_export_status: exportfs installed but no rpc.mountd → ok (no competing mountd)" {
  MOUNTD= run nfs_export_status "${L4T}"
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

@test "nfs_export_status: etab unreadable → warn that the exports cannot be verified" {
  rm -f "${ETAB}"
  MOUNTD=1 run nfs_export_status "${L4T}"
  assert_success
  assert_output --partial $'warn\t'
  assert_output --partial 'etab'
}

# ── nfs_export_l4t_dir ───────────────────────────────────────────────

@test "nfs_export_l4t_dir: maps the single .prepared.yaml under data/jetson_l4t to the export dir" {
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
  : >"${repo}/data/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra/.prepared.yaml"
  L4T_REPO_ROOT="${repo}" run nfs_export_l4t_dir
  assert_success
  assert_output "${BATS_TEST_TMPDIR}/srv/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra"
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
