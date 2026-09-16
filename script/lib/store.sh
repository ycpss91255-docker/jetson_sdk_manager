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
# Moving the checkout changes the id on purpose: the marker then fails
# validation and a human has to confirm (rm the marker, or purge from the
# old path) rather than the scripts guessing.
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
  local version backend repo_id want_id target canon_repo

  [[ -f "${marker}" ]] || _store_reject "no marker at ${marker}" || return 1
  # The marker is only trusted at its one canonical location; a copy
  # elsewhere is not a marker.
  canon_repo="$(readlink -f "${repo_root}")"
  [[ "$(readlink -f "${marker}")" == "${canon_repo}/data/.l4t_store" ]] \
    || _store_reject "marker must be ${canon_repo}/data/.l4t_store, not ${marker}" || return 1

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
      # purge does `rm -f` on this path, so it may only ever be THE repo
      # image — a marker naming any other file is not honoured.
      [[ "$(readlink -f "${target}")" == "${canon_repo}/data/jetson_l4t.img" ]] \
        || _store_reject "image must be ${canon_repo}/data/jetson_l4t.img, not ${target}" || return 1
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

# ── provisioning (host_setup.sh step 0) ─────────────────────────────

# Overridable for tests; defaults are the real tools. STAT_BIN only serves
# the fstype probe so a stub cannot disturb store_same_inode's real stat.
STAT_BIN="${STAT_BIN:-stat}"
STORE_MOUNT_BIN="${STORE_MOUNT_BIN:-mount}"
STORE_MOUNTPOINT_BIN="${STORE_MOUNTPOINT_BIN:-mountpoint}"
STORE_FINDMNT_BIN="${STORE_FINDMNT_BIN:-findmnt}"
STORE_LOSETUP_BIN="${STORE_LOSETUP_BIN:-losetup}"

# store_mount_is_image <mountpoint> <image>
# True when <mountpoint> is a loop mount whose loop device is backed by
# <image>: findmnt gives /dev/loopN, `losetup -j <image>` lists every loop
# device backed by that file. Anything else (a foreign image, a bind, a
# different filesystem) is not ours.
store_mount_is_image() {
  local mnt="$1" image="$2" src
  src="$("${STORE_FINDMNT_BIN}" -n -o SOURCE "${mnt}" 2>/dev/null)" || return 1
  [[ "${src}" == /dev/loop* ]] || return 1
  "${STORE_LOSETUP_BIN}" -j "${image}" 2>/dev/null | grep -q "^${src}:"
}

_store_reject_foreign_mount() {
  emit_error \
    --category host-config \
    --detail "$1 is mounted but not backed by $2" \
    --action "Unmount it (sudo umount $1) if it is stale, then re-run host_setup.sh" \
    --action "If it is deliberately mounted from an ext4 directory, say so with L4T_STORE_DIR=<that directory>"
  return 1
}

# store_fstype_of <path>
store_fstype_of() {
  "${STAT_BIN}" -f -c %T "$1" 2>/dev/null
}

# store_paths <repo_root>
# Sets STORE_DATA_DIR / STORE_MARKER / STORE_IMAGE for the given checkout.
store_paths() {
  local repo_root="$1"
  STORE_DATA_DIR="${repo_root}/data/jetson_l4t"
  STORE_MARKER="${repo_root}/data/.l4t_store"
  STORE_IMAGE="${repo_root}/data/jetson_l4t.img"
}

_store_ok()   { printf '  ok: %s\n' "$1" >&2; }
_store_warn() { printf '  \033[33mwarning: %s\033[0m\n' "$1" >&2; }

# _store_require_tools <tool>...
_store_require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
  done
  (( ${#missing[@]} == 0 )) && return 0
  emit_error \
    --category host-config \
    --detail "missing host tool(s) for the L4T data store: ${missing[*]}" \
    --action "Install them: sudo apt install e2fsprogs util-linux" \
    --action "Or point L4T_STORE_DIR at an existing ext4 directory to skip the image step"
  return 1
}

# _store_owner — the container's non-root user is the invoking host user
# (USER_UID/GID in .env come from id -u/-g), so chown the store root to the
# real user even when this runs under sudo.
_store_owner() {
  printf '%s:%s' "${SUDO_UID:-$(id -u)}" "${SUDO_GID:-$(id -g)}"
}

# _store_provision_loop <repo_root>
_store_provision_loop() {
  local repo_root="$1" size="${L4T_STORE_SIZE:-40G}"
  _store_require_tools truncate mkfs.ext4 "${STORE_MOUNT_BIN}" "${STORE_MOUNTPOINT_BIN}" losetup || return 1
  if [[ ! -f "${STORE_IMAGE}" ]]; then
    store_size_check "${size}" || return 1
    # Sparse: logical ${size}, physical grows with use. ntfs-3g honours the
    # hole on creation; whether later writes stay compact is up to the
    # driver, so the host still needs the real space free.
    truncate -s "${size}" "${STORE_IMAGE}"
    mkfs.ext4 -q -F -m 0 "${STORE_IMAGE}" >/dev/null
    _store_ok "created ext4 image ${STORE_IMAGE} (${size}, sparse)"
  else
    _store_ok "reusing ext4 image ${STORE_IMAGE}"
  fi
  if "${STORE_MOUNTPOINT_BIN}" -q "${STORE_DATA_DIR}"; then
    store_mount_is_image "${STORE_DATA_DIR}" "${STORE_IMAGE}" \
      || _store_reject_foreign_mount "${STORE_DATA_DIR}" "${STORE_IMAGE}" || return 1
    _store_ok "${STORE_DATA_DIR} already mounted from ${STORE_IMAGE}"
  else
    if ! sudo "${STORE_MOUNT_BIN}" -o loop "${STORE_IMAGE}" "${STORE_DATA_DIR}"; then
      emit_error \
        --category host-config \
        --detail "loop-mounting ${STORE_IMAGE} on ${STORE_DATA_DIR} failed" \
        --action "Check the image: sudo e2fsck -f ${STORE_IMAGE}" \
        --action "If it is beyond repair: ./script/clean.sh purge, then re-run host_setup.sh"
      return 1
    fi
    # Fresh mount root is owned by root; hand it to the container user so
    # prepare.sh can write. Never recursive — a populated store keeps the
    # root-owned rootfs files apply_binaries.sh produced.
    sudo chown "$(_store_owner)" "${STORE_DATA_DIR}"
    _store_ok "${STORE_DATA_DIR} ← loop ${STORE_IMAGE}"
  fi
  store_marker_write "${STORE_MARKER}" backend=loop-image \
    "repo_id=$(store_repo_id "${repo_root}")" "image=${STORE_IMAGE}"
}

# _store_provision_dir <repo_root> <store_dir>
_store_provision_dir() {
  local repo_root="$1" store="$2" fstype
  _store_require_tools "${STORE_MOUNT_BIN}" "${STORE_MOUNTPOINT_BIN}" || return 1
  mkdir -p "${store}"
  fstype="$(store_fstype_of "${store}")"
  if ! store_fstype_is_unix "${fstype}"; then
    emit_error \
      --category permission \
      --detail "L4T_STORE_DIR=${store} is on ${fstype}, which cannot preserve setuid / ownership" \
      --action "Point L4T_STORE_DIR at an ext4 / xfs / btrfs directory, or unset it to use the in-repo ext4 image"
    return 1
  fi
  if "${STORE_MOUNTPOINT_BIN}" -q "${STORE_DATA_DIR}"; then
    store_same_inode "${STORE_DATA_DIR}" "${store}" \
      || _store_reject_foreign_mount "${STORE_DATA_DIR}" "${store}" || return 1
    _store_ok "${STORE_DATA_DIR} already mounted from ${store}"
  else
    sudo "${STORE_MOUNT_BIN}" --bind "${store}" "${STORE_DATA_DIR}"
    _store_ok "${STORE_DATA_DIR} ← bind ${store}"
  fi
  store_marker_write "${STORE_MARKER}" backend=directory-bind \
    "repo_id=$(store_repo_id "${repo_root}")" "store=${store}"
}

# store_setup <repo_root>
# Make ${repo_root}/data/jetson_l4t a unix filesystem. Precedence:
#   1. a valid marker (backend re-detection is skipped; a marker that fails
#      validation — e.g. the checkout was moved, so repo_id changed — aborts
#      and asks for a human rather than provisioning on top);
#   2. no marker but the image exists → loop-image, marker re-created
#      (crash window between mount and marker write);
#   3. no marker, no image, but data/jetson_l4t is already a mountpoint →
#      fail closed unless L4T_STORE_DIR names what it is mounted from
#      (a mounted ext4 would otherwise read as "native" and be trusted);
#   4. otherwise detect from the filesystem type.
store_setup() {
  local repo_root="$1" backend fstype
  store_paths "${repo_root}"
  mkdir -p "${STORE_DATA_DIR}"

  if [[ -f "${STORE_MARKER}" ]]; then
    store_marker_validate "${STORE_MARKER}" "${repo_root}" || return 1
    backend="$(store_marker_read "${STORE_MARKER}" backend)"
  elif [[ -f "${STORE_IMAGE}" && -z "${L4T_STORE_DIR:-}" ]]; then
    _store_warn "no marker but ${STORE_IMAGE} exists — recovering (loop-image)"
    backend="loop-image"
  elif "${STORE_MOUNTPOINT_BIN}" -q "${STORE_DATA_DIR}" && [[ -z "${L4T_STORE_DIR:-}" ]] \
      && [[ "${L4T_STORE_BACKEND:-}" != "native" ]]; then
    emit_error \
      --category host-config \
      --detail "${STORE_DATA_DIR} is already a mountpoint of unknown origin ($("${STORE_FINDMNT_BIN}" -n -o SOURCE "${STORE_DATA_DIR}" 2>/dev/null || echo '?')) and there is no data/.l4t_store marker" \
      --action "If you mounted an ext4 directory there yourself, re-run with L4T_STORE_DIR=<that directory> so the repo can track it" \
      --action "Otherwise unmount it (sudo umount ${STORE_DATA_DIR}) and re-run host_setup.sh"
    return 1
  else
    fstype="$(store_fstype_of "${STORE_DATA_DIR}")"
    backend="$(store_backend_detect "${fstype}")" || return 1
  fi

  case "${backend}" in
    native)
      _store_ok "native unix filesystem (${fstype:-marker}) — nothing to provision"
      ;;
    loop-image)
      _store_provision_loop "${repo_root}" || return 1
      ;;
    directory-bind)
      local store
      store="${L4T_STORE_DIR:-$(store_marker_read "${STORE_MARKER}" store 2>/dev/null || true)}"
      [[ -n "${store}" ]] || { printf 'store: directory-bind needs L4T_STORE_DIR\n' >&2; return 1; }
      _store_provision_dir "${repo_root}" "${store}" || return 1
      ;;
  esac
  # Exported for the caller's banner / follow-up steps (host_setup.sh).
  # shellcheck disable=SC2034
  STORE_BACKEND="${backend}"
}
