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
