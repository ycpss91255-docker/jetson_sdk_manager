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
# ones (the /srv/jetson_l4t bridge from host_setup.sh step 5, #52).
#
# Re-running the export right before every flash matters: when prepare
# regenerates tools/kernel_flash/images (clean.sh build), the file handle
# behind the old export goes stale ("mount.nfs: Stale file handle"), so
# nfs_export_on unexports, re-exports and flushes (`exportfs -f`) each time.
#
# Sourced by host_setup.sh, host_teardown.sh and jetson.sh (status / flash
# preflight). Every external tool is overridable so the bats suite can drive
# it with PATH stubs and tmp dirs — no root, no real nfsd.

set -euo pipefail

# Caller must have already sourced errors.sh.
if ! declare -F emit_error >/dev/null; then
  printf 'nfs_export.sh: emit_error not defined — source errors.sh first\n' >&2
  return 1
fi

# The initrd's flash network (NVIDIA's default `--network usb0` →
# fc00:1:1::/48; the host side is fc00:1:1::1).
NFS_EXPORT_CLIENT="${NFS_EXPORT_CLIENT:-fc00:1:1::/48}"
# NVIDIA's PERMISSION_STR, verbatim. rw is required (see the header).
NFS_EXPORT_OPTS="${NFS_EXPORT_OPTS:-rw,nohide,insecure,no_subtree_check,async,no_root_squash}"
EXPORTFS_BIN="${EXPORTFS_BIN:-exportfs}"
PGREP_BIN="${PGREP_BIN:-pgrep}"

_nfs_ok()   { printf '  ok: %s\n' "$1" >&2; }
_nfs_note() { printf '  %s\n' "$1" >&2; }

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

# nfs_export_spec <path> — exportfs's "<client>:<path>" argument. An IPv6
# client has to be bracketed or its colons are read as the separator
# (enable_nfs_for_folder in l4t_network_flash.func does the same).
nfs_export_spec() {
  local client="${NFS_EXPORT_CLIENT}"
  [[ "${client}" == *:* ]] && client="[${client}]"
  printf '%s:%s' "${client}" "$1"
}

# nfs_export_available — true when the host has nfs-kernel-server's exportfs.
# Without it there is no host mountd to compete with the container's, and
# the in-container path works as before.
nfs_export_available() {
  command -v "${EXPORTFS_BIN}" >/dev/null 2>&1
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

# nfs_export_on <l4t_dir>
# Export the three paths to the flash client. Idempotent: each path is
# unexported first (errors ignored — "not exported" is the common case),
# exported with NFS_EXPORT_OPTS, and the kernel export cache is flushed
# once at the end so a regenerated images/ never serves a stale handle.
#   returns 0 — exported, or exportfs is not installed (message, no-op)
#   returns 1 — rootfs / images missing (emit_error): prepare has not
#               produced the tree, or the /srv bridge is not up
nfs_export_on() {
  local l4t="$1" p spec
  if ! nfs_export_available; then
    _nfs_note "exportfs not on PATH (no nfs-kernel-server) — the flash container serves NFS itself"
    return 0
  fi
  while IFS= read -r p; do
    if [[ ! -d "${p}" ]]; then
      emit_error \
        --category host-config \
        --detail "cannot export ${p}: not a directory" \
        --action "Run ./jetson prepare first (it builds rootfs + tools/kernel_flash/images)" \
        --action "Check the /srv/jetson_l4t bridge: ./jetson status, or re-run ./script/host_setup.sh"
      return 1
    fi
  done < <(nfs_export_required_paths "${l4t}")
  # tmp is created by NVIDIA's flash-time network_prerequisite, so a freshly
  # prepared tree does not have it yet; the tree is root-owned after
  # apply_binaries, hence sudo.
  [[ -d "${l4t}/tools/kernel_flash/tmp" ]] || sudo mkdir -p "${l4t}/tools/kernel_flash/tmp"
  while IFS= read -r p; do
    spec="$(nfs_export_spec "${p}")"
    sudo "${EXPORTFS_BIN}" -u "${spec}" >/dev/null 2>&1 || true
    sudo "${EXPORTFS_BIN}" -o "${NFS_EXPORT_OPTS}" "${spec}"
  done < <(nfs_export_paths "${l4t}")
  sudo "${EXPORTFS_BIN}" -f
  _nfs_ok "exported to ${NFS_EXPORT_CLIENT} (${NFS_EXPORT_OPTS}):"
  while IFS= read -r p; do _nfs_note "  ${p}"; done < <(nfs_export_paths "${l4t}")
}

# nfs_export_off <l4t_dir>
# Unexport the three paths (by name — the tree may already be gone) and
# flush. "not exported" is ignored, so teardown is idempotent.
nfs_export_off() {
  local l4t="$1" p
  nfs_export_available || return 0
  while IFS= read -r p; do
    sudo "${EXPORTFS_BIN}" -u "$(nfs_export_spec "${p}")" >/dev/null 2>&1 || true
  done < <(nfs_export_paths "${l4t}")
  sudo "${EXPORTFS_BIN}" -f
  _nfs_ok "unexported ${l4t}/{rootfs,tools/kernel_flash/{images,tmp}}"
}

# nfs_host_mountd_running — true when an rpc.mountd process exists. Run on
# the host this sees the host's own nfs-kernel-server (the one that answers
# the kernel's upcalls with /etc/exports and causes the #101 hang when it
# has nothing to say about the L4T tree).
nfs_host_mountd_running() {
  "${PGREP_BIN}" -x rpc.mountd >/dev/null 2>&1
}

# nfs_export_current — the paths currently exported by the host, one per
# line. Read from the export table exportfs maintains (/var/lib/nfs/etab,
# one "<path>\t<client>(<opts>)" line each, world-readable on stock
# installs) because `exportfs -s` as a normal user fails on the table's
# lock file — and status must never prompt for sudo. Falls back to
# `exportfs -s` (same line shape) when the table is not readable. Empty
# when exportfs is missing.
NFS_ETAB="${NFS_ETAB:-/var/lib/nfs/etab}"
nfs_export_current() {
  nfs_export_available || return 0
  if [[ -r "${NFS_ETAB}" ]]; then
    awk 'NF { print $1 }' "${NFS_ETAB}"
  else
    "${EXPORTFS_BIN}" -s 2>/dev/null | awk 'NF { print $1 }' || true
  fi
}

# nfs_export_missing <l4t_dir> — the paths of <l4t_dir> NOT currently
# exported, one per line (empty = all three are).
nfs_export_missing() {
  local l4t="$1" current p
  current="$(nfs_export_current)"
  while IFS= read -r p; do
    grep -qxF -- "${p}" <<<"${current}" || printf '%s\n' "${p}"
  done < <(nfs_export_paths "${l4t}")
}

# nfs_export_status <l4t_dir|''>
# One "<ok|warn>\t<message>" line for ./jetson status (lib/status.sh
# convention). <l4t_dir> empty = no prepared tree yet.
#   ok    no exportfs on the host (container path), or no host rpc.mountd,
#         or the exports are all there
#   warn  a host rpc.mountd is running but the exports are missing — the
#         exact #101 hang; ./jetson flash fixes it (nfs_export_on)
nfs_export_status() {
  local l4t="${1:-}" missing
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
  missing="$(nfs_export_missing "${l4t}")"
  if [[ -z "${missing}" ]]; then
    printf 'ok\thost rpc.mountd running and the L4T tree is exported to %s (rootfs, kernel_flash/images, kernel_flash/tmp)\n' "${NFS_EXPORT_CLIENT}"
  else
    printf 'warn\thost rpc.mountd running but not exporting %s — the board'"'"'s mount.nfs would hang (#101); ./jetson flash exports them (or ./script/host_setup.sh)\n' \
      "$(printf '%s\n' "${missing}" | sed "s#^${l4t}/##" | paste -sd, -)"
  fi
}

# nfs_export_l4t_dirs
# HOST-namespace paths of every prepared L4T tree, one per line (0..n): the
# directory of each .prepared.yaml under data/jetson_l4t (same rule as
# lib/status.sh::status_markers), re-rooted at the /srv/jetson_l4t bridge
# (L4T_EXPORT_DIR) — the path the kernel nfsd resolves (#52). No yq on the
# host, so the marker's location is the source, not its contents.
nfs_export_l4t_dirs() {
  local repo="${L4T_REPO_ROOT:?nfs_export_l4t_dirs: L4T_REPO_ROOT unset}"
  local export_dir="${L4T_EXPORT_DIR:-/srv/jetson_l4t}"
  local data="${repo}/data/jetson_l4t" marker
  while IFS= read -r marker; do
    [[ -n "${marker}" ]] || continue
    marker="$(dirname "${marker}")"
    printf '%s\n' "${export_dir}/${marker#"${data}/"}"
  done < <(find "${data}" -maxdepth 3 -name .prepared.yaml 2>/dev/null | sort)
}

# nfs_export_l4t_dir
# The HOST-namespace path of THE prepared L4T tree — the one-marker rule
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
