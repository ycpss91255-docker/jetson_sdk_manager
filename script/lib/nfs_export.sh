#!/usr/bin/env bash
# nfs_export.sh — export the prepared L4T tree from the HOST NFS server (#101).
#
# l4t_initrd_flash.sh (inside the flash container, --network host) runs
# `exportfs` + its own rpc.mountd to serve the flash payload to the Jetson's
# initrd. The kernel nfsd is shared with the host, and when the host ALSO
# runs nfs-kernel-server its rpc.mountd answers the kernel's export upcalls
# with the host's (empty) /etc/exports — the board's `mount.nfs
# [fc00:1:1::1]:…/rootfs /mnt` then hangs forever (nfsd `net` tcpconn
# climbs, `rc` never moves) and the flash ends in "Either the device cannot
# mount the NFS server on the host or a flash command has failed".
#
# The fix is to export the same three directories on the host, to the same
# client, with NVIDIA's permission string (PERMISSION_STR in
# tools/kernel_flash/l4t_network_flash.func). `rw` is mandatory: the board
# mounts rootfs on /mnt and chroots into it (a default `ro` export fails
# with "mktemp: … Read-only file system"). Paths are the HOST-namespace
# ones (the /srv/jetson_l4t bridge from host_setup.sh step 5, #52). This
# happens whenever the host HAS exportfs (nfs-kernel-server installed) —
# not only while its mountd is running — because exporting is harmless
# and the daemon may come up later in the boot.
#
# Re-running the export right before every flash matters: when prepare
# regenerates tools/kernel_flash/images (clean.sh build), the file handle
# behind the old export goes stale ("mount.nfs: Stale file handle"), so
# nfs_export_on unexports, re-exports and flushes (`exportfs -f`) each time.
#
# Trust model (review round 1): the export runs as root (./jetson's
# `sudo -v` is cached by then), so NOTHING handed to sudo may come from the
# caller's environment — a user-set EXPORTFS_BIN would be an arbitrary root
# execution. Production therefore uses only the literal constants below
# (/usr/sbin/exportfs, /var/lib/nfs/etab, /srv/jetson_l4t, the client, the
# options), and every privileged call asserts that. The bats suite uses an
# explicit test mode instead: NFS_EXPORT_TEST_ROOT=<dir> → exportfs is
# <dir>/bin/exportfs, the export table <dir>/etab, the export dir
# <dir>/srv/jetson_l4t, and exportfs runs DIRECTLY — no sudo at all — with
# a "[test mode]" line printed when the lib is sourced. Round 2: every
# path a privileged call touches is confined on the CANONICAL filesystem
# (nfs_path_confined: no `..`, readlink -f under the export dir, symlink
# escapes refused) — also the unexport side, incl. entries read from etab.
#
# Sourced by host_setup.sh, host_teardown.sh and jetson.sh (status / flash
# preflight).

set -euo pipefail

# Caller must have already sourced errors.sh.
if ! declare -F emit_error >/dev/null; then
  printf 'nfs_export.sh: emit_error not defined — source errors.sh first\n' >&2
  return 1
fi

# ── constants (literals; never from the environment) ─────────────────
# The initrd's flash network (NVIDIA's default `--network usb0` →
# fc00:1:1::/48; the host side is fc00:1:1::1).
NFS_EXPORT_CLIENT='fc00:1:1::/48'
# NVIDIA's PERMISSION_STR, verbatim. rw is required (see the header).
NFS_EXPORT_OPTS='rw,nohide,insecure,no_subtree_check,async,no_root_squash'
NFS_EXPORTFS_PROD='/usr/sbin/exportfs'
NFS_ETAB_PROD='/var/lib/nfs/etab'
# Must equal volume.sh's L4T_ROOT_DEFAULT and host_setup.sh's bridge path.
NFS_EXPORT_DIR_PROD='/srv/jetson_l4t'

# ── test mode ────────────────────────────────────────────────────────
# Only the presence of NFS_EXPORT_TEST_ROOT is read from the environment;
# everything else derives from it. Never set it on a real host.
NFS_EXPORT_TEST_ROOT="${NFS_EXPORT_TEST_ROOT:-}"
if [[ -n "${NFS_EXPORT_TEST_ROOT}" ]]; then
  printf '[nfs_export] [test mode] NFS_EXPORT_TEST_ROOT=%s — exportfs runs without sudo from %s/bin\n' \
    "${NFS_EXPORT_TEST_ROOT}" "${NFS_EXPORT_TEST_ROOT}" >&2
fi

nfs_export_test_mode() { [[ -n "${NFS_EXPORT_TEST_ROOT}" ]]; }

# nfs_exportfs_bin / nfs_etab / nfs_export_dir — the three locations, each
# a production literal or its test-root counterpart.
nfs_exportfs_bin() {
  if nfs_export_test_mode; then printf '%s/bin/exportfs\n' "${NFS_EXPORT_TEST_ROOT}"
  else printf '%s\n' "${NFS_EXPORTFS_PROD}"; fi
}
nfs_etab() {
  if nfs_export_test_mode; then printf '%s/etab\n' "${NFS_EXPORT_TEST_ROOT}"
  else printf '%s\n' "${NFS_ETAB_PROD}"; fi
}
nfs_export_dir() {
  if nfs_export_test_mode; then printf '%s/srv/jetson_l4t\n' "${NFS_EXPORT_TEST_ROOT}"
  else printf '%s\n' "${NFS_EXPORT_DIR_PROD}"; fi
}

_nfs_ok()   { printf '  ok: %s\n' "$1" >&2; }
_nfs_note() { printf '  %s\n' "$1" >&2; }
_nfs_warn() { printf '  \033[33mwarning: %s\033[0m\n' "$1" >&2; }

# nfs_path_confined <path> — true when <path> is a strict descendant of
# the export dir on the CANONICAL filesystem, i.e. what root would really
# touch. A string prefix is not enough (review round 2): `..` components
# and symlinks under /srv/jetson_l4t can point anywhere. Rules:
#   - literal must be "<dir>/<something>" with no `.` / `..` component
#   - readlink -f of the path (or, when it does not exist yet — tmp before
#     its mkdir, a tree already deleted before teardown — of its nearest
#     existing parent) must lie inside readlink -f of the export dir; the
#     export dir itself is only accepted for a NON-existing path's parent
# So a symlink whose target is inside the dir passes; one that escapes,
# or a `..` hop, does not. The export dir may itself be a symlink / bind
# (the bridge) — it is canonicalised too.
nfs_path_confined() {
  local p="$1" dir dir_c probe c
  dir="$(nfs_export_dir)"
  [[ "${p}" == "${dir}/"?* ]] || return 1
  case "/${p}/" in */../*|*/./*) return 1 ;; esac
  dir_c="$(readlink -f -- "${dir}" 2>/dev/null)" || return 1
  [[ -n "${dir_c}" ]] || return 1
  if [[ -e "${p}" || -L "${p}" ]]; then
    c="$(readlink -f -- "${p}" 2>/dev/null)" || return 1
    [[ -n "${c}" && "${c}" == "${dir_c}/"?* ]]
    return
  fi
  # Nearest existing ancestor.
  probe="${p%/*}"
  while [[ -n "${probe}" && ! -e "${probe}" && ! -L "${probe}" ]]; do probe="${probe%/*}"; done
  [[ -n "${probe}" ]] || return 1
  c="$(readlink -f -- "${probe}" 2>/dev/null)" || return 1
  [[ -n "${c}" ]] && { [[ "${c}" == "${dir_c}" ]] || [[ "${c}" == "${dir_c}/"?* ]]; }
}

# _nfs_assert_our_path <path> — nfs_path_confined or emit_error. Every
# privileged exportfs / mkdir target goes through this first.
_nfs_assert_our_path() {
  nfs_path_confined "$1" && return 0
  emit_error \
    --category host-config \
    --detail "refusing to touch ${1}: not (canonically) under $(nfs_export_dir) — a .. component, or a symlink pointing outside" \
    --action "The L4T tree is resolved from data/jetson_l4t's .prepared.yaml and re-rooted at $(nfs_export_dir); do not pass other paths" \
    --action "Check for symlinks under $(nfs_export_dir): find $(nfs_export_dir) -maxdepth 4 -type l"
  return 1
}

# _nfs_exportfs <args...> — run exportfs. Production: `sudo /usr/sbin/exportfs`
# (the literal, asserted here again). Test mode: <root>/bin/exportfs, no sudo.
_nfs_exportfs() {
  local bin
  bin="$(nfs_exportfs_bin)"
  if nfs_export_test_mode; then
    "${bin}" "$@"
  else
    [[ "${bin}" == "${NFS_EXPORTFS_PROD}" ]] || { printf 'nfs_export: refusing to sudo %s\n' "${bin}" >&2; return 1; }
    sudo "${bin}" "$@"
  fi
}

# _nfs_mkdir <dir> — the tree is root-owned after apply_binaries, so
# production needs sudo; the path is asserted to be ours first.
_nfs_mkdir() {
  _nfs_assert_our_path "$1" || return 1
  if nfs_export_test_mode; then mkdir -p -- "$1"
  else sudo mkdir -p -- "$1"; fi
}

# nfs_export_paths <l4t_dir>
# The three directories l4t_initrd_flash serves over NFS, one per line, in
# export order. rootfs + images are what the board mounts; tmp is the
# scratch dir NVIDIA's network_prerequisite creates and exports to
# 127.0.0.1 so /etc/exports is never empty (harmless to export as well —
# it is what the verified manual fix in #101 did).
nfs_export_paths() {
  local l4t="$1"
  printf '%s\n' "${l4t}/rootfs" "${l4t}/tools/kernel_flash/images" "${l4t}/tools/kernel_flash/tmp"
}

# nfs_export_required_paths <l4t_dir> — the two paths that must already
# exist to export (prepare's products; tmp is created on demand).
nfs_export_required_paths() {
  printf '%s\n' "$1/rootfs" "$1/tools/kernel_flash/images"
}

# nfs_export_ready <l4t_dir> — true when the tree can be exported now.
# False after clean.sh build / rootfs (marker kept, directories gone) or
# when the /srv bridge is not up; callers that run BEFORE prepare rebuilds
# the tree (host_setup.sh) skip on false instead of failing.
nfs_export_ready() {
  local p
  while IFS= read -r p; do
    [[ -d "${p}" ]] || return 1
  done < <(nfs_export_required_paths "$1")
}

# nfs_export_spec <path> [client] — exportfs's "<client>:<path>" argument.
# An IPv6 client has to be bracketed or its colons are read as the
# separator (enable_nfs_for_folder in l4t_network_flash.func does the same).
nfs_export_spec() {
  local client="${2:-${NFS_EXPORT_CLIENT}}"
  [[ "${client}" == *:* ]] && client="[${client}]"
  printf '%s:%s' "${client}" "$1"
}

# nfs_export_available — true when the host has nfs-kernel-server's exportfs.
# Without it there is no host mountd to compete with the container's, and
# the in-container path works as before.
nfs_export_available() {
  [[ -x "$(nfs_exportfs_bin)" ]]
}

# nfs_export_on <l4t_dir>
# Export the three paths to the flash client. Idempotent: each path is
# unexported first (errors ignored — "not exported" is the common case),
# exported with NFS_EXPORT_OPTS, and the kernel export cache is flushed
# once at the end so a regenerated images/ never serves a stale handle.
#   returns 0 — exported, or exportfs is not installed (message, no-op)
#   returns 1 — <l4t_dir> not under the export dir; rootfs / images missing
#               (emit_error: prepare has not produced the tree, or the /srv
#               bridge is not up); tmp not creatable; an export or the
#               flush failed (the remaining exports and the flush are still
#               attempted so the table is never left half-refreshed)
nfs_export_on() {
  local l4t="$1" p spec failed=""
  if ! nfs_export_available; then
    _nfs_note "$(nfs_exportfs_bin) not installed (no nfs-kernel-server) — the flash container serves NFS itself"
    return 0
  fi
  _nfs_assert_our_path "${l4t}" || return 1
  while IFS= read -r p; do
    if [[ ! -d "${p}" ]]; then
      emit_error \
        --category host-config \
        --detail "cannot export ${p}: not a directory" \
        --action "Run ./jetson prepare first (it builds rootfs + tools/kernel_flash/images)" \
        --action "Check the $(nfs_export_dir) bridge: ./jetson status, or re-run ./script/host_setup.sh"
      return 1
    fi
    _nfs_assert_our_path "${p}" || return 1
  done < <(nfs_export_required_paths "${l4t}")
  # tmp is created by NVIDIA's flash-time network_prerequisite, so a freshly
  # prepared tree does not have it yet. _nfs_mkdir confines the path via its
  # nearest existing parent before creating anything.
  if [[ ! -d "${l4t}/tools/kernel_flash/tmp" ]]; then
    if ! _nfs_mkdir "${l4t}/tools/kernel_flash/tmp"; then
      nfs_path_confined "${l4t}/tools/kernel_flash/tmp" || return 1   # already reported
      emit_error \
        --category host-config \
        --detail "cannot create ${l4t}/tools/kernel_flash/tmp" \
        --action "Check the path (a file in the way?) and permissions, then ./jetson flash again"
      return 1
    fi
  fi
  # Confine every export target once more on the canonical filesystem, now
  # that all three exist — the check right before the privileged call.
  while IFS= read -r p; do
    _nfs_assert_our_path "${p}" || return 1
  done < <(nfs_export_paths "${l4t}")
  while IFS= read -r p; do
    spec="$(nfs_export_spec "${p}")"
    _nfs_exportfs -u "${spec}" >/dev/null 2>&1 || true
    _nfs_exportfs -o "${NFS_EXPORT_OPTS}" "${spec}" || failed="${failed} ${p}"
  done < <(nfs_export_paths "${l4t}")
  if ! _nfs_exportfs -f; then
    _nfs_warn "exportfs -f failed — the kernel export cache was not flushed; a re-prepared tree may serve a stale file handle"
    failed="${failed} (flush)"
  fi
  if [[ -n "${failed}" ]]; then
    emit_error \
      --category host-config \
      --detail "exportfs failed for:${failed}" \
      --action "Run it by hand to see why: sudo $(nfs_exportfs_bin) -o ${NFS_EXPORT_OPTS} \"$(nfs_export_spec "${l4t}/rootfs")\"" \
      --action "Is nfs-kernel-server healthy? systemctl status nfs-kernel-server"
    return 1
  fi
  _nfs_ok "exported to ${NFS_EXPORT_CLIENT} (${NFS_EXPORT_OPTS}):"
  while IFS= read -r p; do _nfs_note "  ${p}"; done < <(nfs_export_paths "${l4t}")
}

# _nfs_unexport_specs — read "<client>\t<path>" lines on stdin, unexport
# each (by name — the tree may already be gone; "not exported" ignored),
# then flush once. Returns 1 when the flush fails.
_nfs_unexport_specs() {
  local client p n=0
  while IFS=$'\t' read -r client p; do
    [[ -n "${p}" ]] || continue
    # Same confinement as the export side, per entry — the path may come from
    # the export table, which root maintains but is still data, not trust.
    if ! nfs_path_confined "${p}"; then
      _nfs_note "skipping ${p}: not (canonically) under $(nfs_export_dir)"
      continue
    fi
    n=$((n+1))
    _nfs_exportfs -u "$(nfs_export_spec "${p}" "${client}")" >/dev/null 2>&1 || true
  done
  (( n > 0 )) || return 0        # nothing was ours: nothing to flush
  if ! _nfs_exportfs -f; then
    _nfs_warn "exportfs -f failed — the kernel export cache was not flushed"
    return 1
  fi
}

# nfs_export_off <l4t_dir>
# Unexport the three paths of one tree and flush. Idempotent.
nfs_export_off() {
  local l4t="$1" p
  nfs_export_available || return 0
  if ! nfs_path_confined "${l4t}"; then
    _nfs_note "skipping ${l4t}: not (canonically) under $(nfs_export_dir) — nothing unexported"
    return 0
  fi
  while IFS= read -r p; do printf '%s\t%s\n' "${NFS_EXPORT_CLIENT}" "${p}"; done < <(nfs_export_paths "${l4t}") \
    | _nfs_unexport_specs || return 1
  _nfs_ok "unexported ${l4t}/{rootfs,tools/kernel_flash/{images,tmp}}"
}

# nfs_export_off_all <l4t_dir>...
# Teardown: the three paths of every given tree PLUS every entry of the
# export table that lives under the export dir — so exports left behind
# after `clean.sh l4t` removed the marker (or from an earlier layout) go
# too; otherwise they pin the /srv bridge and its umount says "busy".
# Deduplicated, one flush. Never touches paths outside the export dir.
nfs_export_off_all() {
  local l4t p specs n client
  nfs_export_available || return 0
  specs="$(
    for l4t in "$@"; do
      [[ -n "${l4t}" ]] || continue
      while IFS= read -r p; do printf '%s\t%s\n' "${NFS_EXPORT_CLIENT}" "${p}"; done < <(nfs_export_paths "${l4t}")
    done
    nfs_export_table_under "$(nfs_export_dir)/" | cut -f1,2
  )"
  # Deduplicate, then keep only what canonicalises under the export dir
  # (the table is data: a `..` or symlink entry is skipped with a note).
  specs="$(printf '%s\n' "${specs}" | awk -F'\t' 'NF && !seen[$0]++' \
    | while IFS=$'\t' read -r client p; do
        if nfs_path_confined "${p}"; then printf '%s\t%s\n' "${client}" "${p}"
        else _nfs_note "skipping ${p}: not (canonically) under $(nfs_export_dir)"; fi
      done)"
  n="$(printf '%s\n' "${specs}" | grep -c . || true)"
  if (( n == 0 )); then
    _nfs_ok "nothing of ours exported under $(nfs_export_dir)"
    return 0
  fi
  printf '%s\n' "${specs}" | _nfs_unexport_specs || return 1
  _nfs_ok "unexported ${n} path(s) under $(nfs_export_dir)"
}

# nfs_host_mountd_running — true when an rpc.mountd process exists. Run on
# the host this sees the host's own nfs-kernel-server (the one that answers
# the kernel's upcalls with /etc/exports and causes the #101 hang when it
# has nothing to say about the L4T tree). Unprivileged; pgrep from PATH.
nfs_host_mountd_running() {
  pgrep -x rpc.mountd >/dev/null 2>&1
}

# nfs_export_table — the host's export table as "<client>\t<path>\t<opts>"
# lines. Source: /var/lib/nfs/etab, which exportfs maintains as
# "<path>\t<client>(<opts>)" per line, tab separated (a path may contain
# spaces), 0644 on stock installs. Read directly because `exportfs -s` as a
# normal user fails on the table's lock file — and status must never
# prompt for sudo. Clients are normalised to the bare form ("[v6]" → v6).
# Returns 1 when the table is not readable.
nfs_export_table() {
  local etab line p rest client opts
  etab="$(nfs_etab)"
  [[ -r "${etab}" ]] || return 1
  while IFS= read -r line; do
    [[ "${line}" == *$'\t'* ]] || continue
    p="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    client="${rest%%(*}"; client="${client#[}"; client="${client%]}"
    opts="${rest#*(}"; opts="${opts%)}"
    printf '%s\t%s\t%s\n' "${client}" "${p}" "${opts}"
  done <"${etab}"
}

# nfs_export_table_under <prefix> — the table entries whose path starts
# with <prefix>. Empty (rc 0) when the table is unreadable.
nfs_export_table_under() {
  nfs_export_table 2>/dev/null | awk -F'\t' -v pre="$1" 'index($2, pre) == 1' || true
}

# nfs_export_problems <l4t_dir> — one line per path of <l4t_dir> that is
# NOT exported the way the board needs it: "<relative path>: <reason>".
# Empty = all three are exported to NFS_EXPORT_CLIENT with rw.
nfs_export_problems() {
  local l4t="$1" table p client tp opts found
  table="$(nfs_export_table)" || return 1
  while IFS= read -r p; do
    found=""
    while IFS=$'\t' read -r client tp opts; do
      [[ "${tp}" == "${p}" ]] || continue
      found="client ${client}"
      if [[ "${client}" != "${NFS_EXPORT_CLIENT}" ]]; then
        found="exported to ${client}, not ${NFS_EXPORT_CLIENT}"; continue
      fi
      if [[ ",${opts}," != *,rw,* ]]; then
        found="exported to ${client} but not rw"; continue
      fi
      found="ok"; break
    done <<<"${table}"
    case "${found}" in
      ok) ;;
      "") printf '%s: not exported\n' "${p#"${l4t}"/}" ;;
      *)  printf '%s: %s\n' "${p#"${l4t}"/}" "${found}" ;;
    esac
  done < <(nfs_export_paths "${l4t}")
}

# nfs_export_status <l4t_dir|''>
# One "<ok|warn>\t<message>" line for ./jetson status (lib/status.sh
# convention). <l4t_dir> empty = no prepared tree yet.
#   ok    no exportfs on the host (container path), or no host rpc.mountd,
#         or the three paths are exported to the client with rw
#   warn  a host rpc.mountd is running but the exports are missing / to
#         another client / not rw — the exact #101 hang; ./jetson flash
#         fixes it (nfs_export_on). Also warn when the table is unreadable.
nfs_export_status() {
  local l4t="${1:-}" problems
  if ! nfs_export_available; then
    printf 'ok\tno host nfs-kernel-server — the flash container serves NFS itself\n'
    return 0
  fi
  if ! nfs_host_mountd_running; then
    printf 'ok\thost nfs-kernel-server installed but rpc.mountd not running — no competing mountd, the container serves NFS\n'
    return 0
  fi
  if [[ -z "${l4t}" ]]; then
    printf 'ok\thost rpc.mountd running — ./jetson flash exports the L4T tree from it once prepare has built it\n'
    return 0
  fi
  if ! problems="$(nfs_export_problems "${l4t}")"; then
    printf 'warn\thost rpc.mountd running but %s is not readable — cannot verify the L4T exports; sudo %s -s\n' "$(nfs_etab)" "$(nfs_exportfs_bin)"
    return 0
  fi
  if [[ -z "${problems}" ]]; then
    printf 'ok\thost rpc.mountd running and the L4T tree is exported rw to %s (rootfs, kernel_flash/images, kernel_flash/tmp)\n' "${NFS_EXPORT_CLIENT}"
  else
    printf 'warn\thost rpc.mountd running but not exporting the L4T tree as the board needs it (%s) — its mount.nfs would hang (#101); ./jetson flash exports them (or ./script/host_setup.sh)\n' \
      "$(printf '%s\n' "${problems}" | paste -sd';' - | sed 's/;/; /g')"
  fi
}

# nfs_export_l4t_dirs
# Export-dir paths of every prepared L4T tree, one per line (0..n): the
# directory of each .prepared.yaml under data/jetson_l4t (same rule as
# lib/status.sh::status_markers), re-rooted at the export dir — the path
# the kernel nfsd resolves (#52). No yq on the host, so the marker's
# location is the source, not its contents.
nfs_export_l4t_dirs() {
  local repo="${L4T_REPO_ROOT:?nfs_export_l4t_dirs: L4T_REPO_ROOT unset}"
  local export_dir data marker
  export_dir="$(nfs_export_dir)"
  data="${repo}/data/jetson_l4t"
  while IFS= read -r marker; do
    [[ -n "${marker}" ]] || continue
    marker="$(dirname "${marker}")"
    printf '%s\n' "${export_dir}/${marker#"${data}/"}"
  done < <(find "${data}" -maxdepth 3 -name .prepared.yaml 2>/dev/null | sort)
}

# nfs_export_l4t_dir
# The export-dir path of THE prepared L4T tree — the one-marker rule
# ./jetson flash gates on.
#   returns 0 and prints the path — exactly one prepared tree
#   returns 1                     — none (prepare has not run)
#   returns 2                     — more than one (ambiguous; clean.sh l4t)
nfs_export_l4t_dir() {
  local dirs n
  dirs="$(nfs_export_l4t_dirs)"
  n="$(printf '%s\n' "${dirs}" | grep -c . || true)"
  case "${n}" in
    0) return 1 ;;
    1) printf '%s\n' "${dirs}" ;;
    *) return 2 ;;
  esac
}
