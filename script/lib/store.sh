#!/usr/bin/env bash
# store.sh — L4T data-store backend vocabulary (#93).
#
# ./data/jetson_l4t must be a unix filesystem (ext4 / xfs / btrfs) because
# apply_binaries.sh writes setuid + root-owned files. When the checkout sits
# on NTFS / exFAT / FAT the store lives in an ext4 image file INSIDE the repo
# (data/jetson_l4t.img) loop-mounted over data/jetson_l4t — so removing the
# checkout removes everything. Sourced by host_setup.sh, host_teardown.sh and
# clean.sh; the backend is recorded in a versioned marker, data/.l4t_store.
#
# Backends:
#   native          checkout already on a unix FS — nothing to provision
#   loop-image      ext4 image file in the repo, loop-mounted (default fallback)
#   directory-bind  user-supplied ext4 directory (L4T_STORE_DIR), bind-mounted

set -euo pipefail

# Caller must have already sourced errors.sh.
if ! declare -F emit_error >/dev/null; then
  printf 'store.sh: emit_error not defined — source errors.sh first\n' >&2
  return 1
fi

STORE_BACKENDS="native loop-image directory-bind"

# store_fstype_is_unix <fstype>
# True for filesystems that preserve setuid + ownership. Mirrors the list
# init_data_dirs.sh / prepare.sh warn on (fuseblk|ntfs*|exfat|vfat|msdos).
store_fstype_is_unix() {
  case "$1" in
    fuseblk|ntfs*|exfat|vfat|msdos) return 1 ;;
    *) return 0 ;;
  esac
}

# store_backend_detect <fstype>
# Echoes the backend for a checkout whose data/jetson_l4t sits on <fstype>.
# Precedence: L4T_STORE_BACKEND (explicit / CI) > L4T_STORE_DIR (explicit
# directory-bind) > fstype (unix → native, otherwise loop-image).
store_backend_detect() {
  local fstype="$1" forced="${L4T_STORE_BACKEND:-}"
  if [[ -n "${forced}" ]]; then
    case " ${STORE_BACKENDS} " in
      *" ${forced} "*) printf '%s\n' "${forced}"; return 0 ;;
    esac
    printf 'store: unknown backend L4T_STORE_BACKEND=%s (expected one of: %s)\n' \
      "${forced}" "${STORE_BACKENDS}" >&2
    return 1
  fi
  if [[ -n "${L4T_STORE_DIR:-}" ]]; then
    printf 'directory-bind\n'
    return 0
  fi
  if store_fstype_is_unix "${fstype}"; then
    printf 'native\n'
  else
    printf 'loop-image\n'
  fi
}

# ── marker ───────────────────────────────────────────────────────────
# data/.l4t_store: versioned key=value, one per line. Written atomically
# (tmp + rename in the same dir) so a crash mid-write never leaves a
# half-marker for clean.sh purge to act on.

STORE_MARKER_VERSION=1

# store_repo_id <repo_root>
# 16 hex chars identifying this checkout by its canonical path. Recorded in
# the marker so purge refuses to touch a store provisioned by another clone.
store_repo_id() {
  local canon
  canon="$(readlink -f "$1")"
  printf '%s' "${canon}" | sha256sum | cut -c1-16
}

# store_marker_write <marker_path> key=value...
# Always prepends version=${STORE_MARKER_VERSION}.
store_marker_write() {
  local marker="$1"; shift
  local tmp
  tmp="$(mktemp "${marker}.XXXXXX")"
  {
    printf 'version=%s\n' "${STORE_MARKER_VERSION}"
    printf '%s\n' "$@"
  } >"${tmp}"
  mv -f "${tmp}" "${marker}"
}

# store_marker_read <marker_path> <key>
# Echoes the value; returns 1 when the file or the key is absent.
store_marker_read() {
  local marker="$1" key="$2" line
  [[ -f "${marker}" ]] || return 1
  line="$(grep -m1 "^${key}=" "${marker}")" || return 1
  printf '%s\n' "${line#*=}"
}

# _store_reject <reason>  — print a diagnostic and return 1.
_store_reject() {
  printf 'store: marker rejected — %s\n' "$1" >&2
  return 1
}

# _store_path_is_inside <path> <root>
_store_path_is_inside() {
  local p="$1" root="$2"
  [[ "${p}" == "${root}" || "${p}" == "${root}/"* ]]
}

# store_marker_validate <marker_path> <repo_root>
# The single gate every destructive step (purge) must pass. Refuses to bless
# a marker that is malformed, from another checkout, of an unknown backend
# or whose target is not what the backend expects. Diagnostics go to stderr.
store_marker_validate() {
  local marker="$1" repo_root="$2"
  local version backend repo_id want_id target

  [[ -f "${marker}" ]] || _store_reject "no marker at ${marker}" || return 1

  version="$(store_marker_read "${marker}" version)" \
    || _store_reject "missing version" || return 1
  [[ "${version}" == "${STORE_MARKER_VERSION}" ]] \
    || _store_reject "unsupported version=${version} (expected ${STORE_MARKER_VERSION})" || return 1

  backend="$(store_marker_read "${marker}" backend)" \
    || _store_reject "missing backend" || return 1

  repo_id="$(store_marker_read "${marker}" repo_id)" \
    || _store_reject "missing repo_id" || return 1
  want_id="$(store_repo_id "${repo_root}")"
  [[ "${repo_id}" == "${want_id}" ]] \
    || _store_reject "repo_id ${repo_id} belongs to another checkout (this repo is ${want_id})" || return 1

  case "${backend}" in
    loop-image)
      target="$(store_marker_read "${marker}" image)" \
        || _store_reject "loop-image marker has no image=" || return 1
      [[ "${target}" == /* ]] || _store_reject "image path is not absolute: ${target}" || return 1
      [[ ! -L "${target}" ]] || _store_reject "image is a symlink: ${target}" || return 1
      [[ -f "${target}" ]] || _store_reject "image is not a regular file: ${target}" || return 1
      ;;
    directory-bind)
      target="$(store_marker_read "${marker}" store)" \
        || _store_reject "directory-bind marker has no store=" || return 1
      [[ "${target}" == /* ]] || _store_reject "store path is not absolute: ${target}" || return 1
      [[ ! -L "${target}" ]] || _store_reject "store is a symlink: ${target}" || return 1
      [[ -d "${target}" ]] || _store_reject "store is not a directory: ${target}" || return 1
      [[ "${target}" != "/" ]] || _store_reject "store is /" || return 1
      [[ "${target}" != "${HOME:-/nonexistent}" ]] || _store_reject "store is \$HOME" || return 1
      ! _store_path_is_inside "$(readlink -f "${target}")" "$(readlink -f "${repo_root}")" \
        || _store_reject "store is inside the repo (a directory-bind store must be on another filesystem): ${target}" || return 1
      ;;
    *)
      _store_reject "unknown backend=${backend} (expected one of: ${STORE_BACKENDS})" || return 1
      ;;
  esac
  return 0
}

# ── image size ───────────────────────────────────────────────────────

# store_size_bytes <N{M|G}>
# Echoes the byte count for a size string like 40G / 256M. Rejects anything
# else (no bare numbers — an ambiguous unit is how you get a 40-byte image).
store_size_bytes() {
  local s="$1" n unit
  [[ "${s}" =~ ^([0-9]+)([MG])$ ]] || return 1
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  (( n > 0 )) || return 1
  case "${unit}" in
    M) printf '%s\n' $(( n * 1024 * 1024 )) ;;
    G) printf '%s\n' $(( n * 1024 * 1024 * 1024 )) ;;
  esac
}

# store_size_check <size> [existing_image]
# 15 GB of L4T tree + rootfs + generated images needs headroom, so 20G is
# the floor (L4T_STORE_MIN_SIZE overrides it — CI uses a 256M fixture).
# An existing image is never shrunk: ext4 does not survive a truncate.
store_size_check() {
  local size="$1" existing="${2:-}" want have min
  want="$(store_size_bytes "${size}")" \
    || { printf 'store: invalid L4T_STORE_SIZE=%s (use e.g. 40G or 256M)\n' "${size}" >&2; return 1; }
  min="$(store_size_bytes "${L4T_STORE_MIN_SIZE:-20G}")"
  if (( want < min )); then
    printf 'store: L4T_STORE_SIZE=%s is below the %s minimum needed for one prepare\n' \
      "${size}" "${L4T_STORE_MIN_SIZE:-20G}" >&2
    return 1
  fi
  if [[ -n "${existing}" && -f "${existing}" ]]; then
    have="$(stat -c %s "${existing}")"
    if (( want < have )); then
      printf 'store: refusing to shrink existing image %s (%s bytes) to %s\n' \
        "${existing}" "${have}" "${size}" >&2
      return 1
    fi
  fi
  return 0
}

# ── mount identity ───────────────────────────────────────────────────

# store_same_inode <path_a> <path_b>
# True when both paths resolve to the same device+inode — the reliable way
# to ask "is /srv/jetson_l4t bound from THIS store?" findmnt renders a
# bind as DEV[/subtree] and a loop root as plain /dev/loopN, so a string
# compare against the source path is wrong in both cases.
store_same_inode() {
  local a b
  a="$(stat -L -c '%d:%i' "$1" 2>/dev/null)" || return 1
  b="$(stat -L -c '%d:%i' "$2" 2>/dev/null)" || return 1
  [[ "${a}" == "${b}" ]]
}
