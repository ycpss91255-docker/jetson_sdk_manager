#!/usr/bin/env bash
# fs.sh — guard against non-unix filesystems that strip setuid / ownership.
#
# NVIDIA's apply_binaries.sh (factory flow, prepare.sh) and SDK Manager
# (cli/gui flow, sdkm-entrypoint.sh) both create a setuid `sudo` and
# root-owned files inside the L4T rootfs. NTFS / exFAT / fuseblk / vfat
# silently drop both, which yields a flashed Jetson whose sudo refuses to
# start. Detect that early and abort with an actionable message, unless the
# caller opts in via JETSON_ALLOW_NON_UNIX_FS=1.
#
# Caller must have sourced errors.sh first (for emit_error).

if ! declare -F emit_error >/dev/null; then
  printf 'fs.sh: emit_error not defined — source errors.sh first\n' >&2
  return 1
fi

# assert_unix_fs <path> <label> [extra emit_error --action args ...]
#
# <label> tags the warning line (e.g. "prepare", "sdkmanager"). Any extra
# args are forwarded verbatim to emit_error, so callers can append a
# context-specific --action between the generic "move to ext4" and the
# final "opt in" action.
assert_unix_fs() {
  local path="$1" label="$2"
  shift 2
  mkdir -p "${path}"
  local fstype
  fstype=$(stat -f -c %T "${path}" 2>/dev/null || true)
  case "${fstype}" in
    ext2/ext3|ext4|xfs|btrfs|zfs|tmpfs|overlayfs)
      return 0
      ;;
    fuseblk|ntfs*|exfat|vfat|msdos)
      if [[ "${JETSON_ALLOW_NON_UNIX_FS:-0}" == "1" ]]; then
        printf '[%s] WARNING: %s is on %s and JETSON_ALLOW_NON_UNIX_FS=1 — continuing anyway. setuid / ownership may be stripped, producing a Jetson whose sudo is broken.\n' \
          "${label}" "${path}" "${fstype}" >&2
        return 0
      fi
      emit_error \
        --category permission \
        --detail "${path} is on ${fstype} — cannot preserve setuid / root ownership (the flashed Jetson would get a broken sudo)" \
        --action "Move this repo to an ext4 / xfs / btrfs partition" \
        "$@" \
        --action "Or opt in to the unsafe path with JETSON_ALLOW_NON_UNIX_FS=1"
      return 1
      ;;
    *)
      printf '[%s] Unknown filesystem type %s for %s — proceeding (verify setuid preservation manually).\n' \
        "${label}" "${fstype}" "${path}" >&2
      return 0
      ;;
  esac
}
