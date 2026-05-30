#!/usr/bin/env bash
# clean.sh — staged cleanup of artifacts produced by prepare.sh.
#
# Always run from the HOST (not inside a container). Operates on the
# L4T data either via a Docker named volume (`jetson_l4t`) or via the
# bind-mounted host directory (`./data/jetson_l4t/`), whichever is
# present. A one-shot alpine container with root inside is used so the
# host caller does not need sudo for files that the container wrote as
# root.
#
# Targets (mutually exclusive; pick one):
#   build   — Remove only generated flash images (tools/kernel_flash/images).
#             Keeps extracted BSP + rootfs + applied binaries. Cheap re-prepare.
#   rootfs  — Remove rootfs/ subtree. Keeps BSP. Re-extract rootfs +
#             re-apply binaries + re-run create_user.
#   l4t     — Wipe everything in the volume / bind mount. Keeps cached
#             tarballs under data/downloads/.
#   all     — l4t + remove all tarballs from data/downloads/.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"

VOLUME_NAME="${VOLUME_NAME:-jetson_l4t}"
BINDMOUNT_PATH_DEFAULT="$(cd "${_HERE}/.." && pwd)/data/jetson_l4t"
BINDMOUNT_PATH="${BINDMOUNT_PATH:-${BINDMOUNT_PATH_DEFAULT}}"
DOWNLOADS_HOST_DIR="${DOWNLOADS_HOST_DIR:-./data/downloads}"

_usage() {
  cat >&2 <<'EOF'
Usage: ./script/clean.sh <target>

Targets:
  build   Remove generated flash images only (tools/kernel_flash/images/).
  rootfs  Remove rootfs/ subtree (keeps BSP).
  l4t     Wipe the L4T volume / bind mount.
  all     l4t + drop cached tarballs from data/downloads/.

Operates on the jetson_l4t Docker volume when present, falling back to
the ./data/jetson_l4t/ bind-mount path. Either way the actual rm runs
inside a transient alpine container as root, so host-side sudo is not
needed.
EOF
}

_docker_required() {
  if ! command -v docker >/dev/null; then
    emit_error \
      --category permission \
      --detail "docker CLI not found on this host" \
      --action "Run clean.sh from the host where you launch make run, not from inside the container"
    exit 1
  fi
}

# Echoes "<source>:/vol" for the docker -v flag — a named volume name
# if `jetson_l4t` exists, otherwise the absolute bind-mount path if it
# has any content. Returns 1 when neither exists; the caller's "nothing
# to do" message keeps clean.sh idempotent.
_resolve_mount_spec() {
  if docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
    printf '%s' "${VOLUME_NAME}:/vol"
    return 0
  fi
  if [[ -d "${BINDMOUNT_PATH}" ]] \
      && [[ -n "$(ls -A "${BINDMOUNT_PATH}" 2>/dev/null)" ]]; then
    printf '%s' "${BINDMOUNT_PATH}:/vol"
    return 0
  fi
  return 1
}

# Run a shell snippet inside alpine:3 with /vol mounted to whichever
# source _resolve_mount_spec picks. Echo a "nothing to do" line and
# return 0 when no source is found — clean is meant to be idempotent.
_volume_exec() {
  local cmd="$1" mount_spec
  if ! mount_spec=$(_resolve_mount_spec); then
    printf '[clean] no L4T volume or bind mount found — nothing to do\n' >&2
    return 0
  fi
  docker run --rm -v "${mount_spec}" alpine:3 sh -c "${cmd}"
}

_clean_build() {
  _docker_required
  printf '[clean] Removing tools/kernel_flash/images/\n' >&2
  _volume_exec 'find /vol -type d -name images -path "*/tools/kernel_flash/*" -exec rm -rf {} + 2>/dev/null || true'
  printf '[clean] Done\n' >&2
}

_clean_rootfs() {
  _docker_required
  printf '[clean] Removing rootfs/ subtrees\n' >&2
  _volume_exec 'find /vol -type d -name rootfs -path "*/Linux_for_Tegra/*" -exec rm -rf {} + 2>/dev/null || true'
  printf '[clean] Done\n' >&2
}

_clean_l4t() {
  _docker_required
  if docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
    printf '[clean] Removing volume %s\n' "${VOLUME_NAME}" >&2
    if ! docker volume rm "${VOLUME_NAME}"; then
      emit_error \
        --category permission \
        --detail "docker volume rm ${VOLUME_NAME} failed — container still mounted?" \
        --action "Stop any running prepare/flash container: make stop"
      exit 1
    fi
    return 0
  fi
  if [[ -d "${BINDMOUNT_PATH}" ]] \
      && [[ -n "$(ls -A "${BINDMOUNT_PATH}" 2>/dev/null)" ]]; then
    printf '[clean] Wiping bind mount %s\n' "${BINDMOUNT_PATH}" >&2
    # rm -rf inside alpine so root-owned files (extracted rootfs) come
    # out without needing host sudo. Trailing /* keeps the bind mount
    # parent dir + its inode intact so the container's bind target
    # resolves on the next prepare.
    docker run --rm -v "${BINDMOUNT_PATH}:/vol" alpine:3 sh -c 'rm -rf /vol/* /vol/.[!.]* 2>/dev/null || true'
    return 0
  fi
  printf '[clean] %s does not exist as volume or bind mount — nothing to do\n' "${VOLUME_NAME}" >&2
}

_clean_all() {
  _clean_l4t
  if [[ -d "${DOWNLOADS_HOST_DIR}" ]]; then
    printf '[clean] Removing cached tarballs in %s\n' "${DOWNLOADS_HOST_DIR}" >&2
    find "${DOWNLOADS_HOST_DIR}" -maxdepth 1 -type f \( -name '*.tbz2' -o -name '*.tar.bz2' \) -delete
  fi
}

main() {
  case "${1:-}" in
    build) _clean_build ;;
    rootfs) _clean_rootfs ;;
    l4t) _clean_l4t ;;
    all) _clean_all ;;
    -h|--help|"") _usage; exit 0 ;;
    *) printf 'clean.sh: unknown target: %s\n\n' "$1" >&2; _usage; exit 2 ;;
  esac
}

main "$@"
