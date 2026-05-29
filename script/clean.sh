#!/usr/bin/env bash
# clean.sh — staged cleanup of artifacts produced by prepare.sh.
#
# Always run from the HOST (not inside a container). Operates on the
# jetson_l4t Docker volume by mounting it into a one-shot alpine
# container, since the host cannot reach named-volume paths directly
# without root.
#
# Targets (mutually exclusive; pick one):
#   build   — Remove only generated flash images (tools/kernel_flash/images).
#             Keeps extracted BSP + rootfs + applied binaries. Cheap re-prepare.
#   rootfs  — Remove rootfs/ subtree. Keeps BSP. Re-extract rootfs +
#             re-apply binaries + re-run create_user.
#   l4t     — `docker volume rm jetson_l4t`. Wipes everything in the
#             volume. Keeps cached tarballs under data/downloads/.
#   all     — l4t + remove all tarballs from data/downloads/.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"

VOLUME_NAME="${VOLUME_NAME:-jetson_l4t}"
DOWNLOADS_HOST_DIR="${DOWNLOADS_HOST_DIR:-./data/downloads}"

_usage() {
  cat >&2 <<'EOF'
Usage: ./script/clean.sh <target>

Targets:
  build   Remove generated flash images only (tools/kernel_flash/images/).
  rootfs  Remove rootfs/ subtree (keeps BSP).
  l4t     Remove the whole jetson_l4t Docker volume.
  all     l4t + drop cached tarballs from data/downloads/.

The volume is operated on via a transient alpine container — no
host-side root is required.
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

_volume_exists() {
  docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1
}

_volume_exec() {
  docker run --rm -v "${VOLUME_NAME}:/vol" alpine:3 sh -c "$1"
}

_clean_build() {
  _docker_required
  if ! _volume_exists; then
    printf '[clean] %s does not exist — nothing to do\n' "${VOLUME_NAME}" >&2
    return 0
  fi
  printf '[clean] Removing tools/kernel_flash/images/ from %s\n' "${VOLUME_NAME}" >&2
  _volume_exec 'find /vol -type d -name images -path "*/tools/kernel_flash/*" -exec rm -rf {} + 2>/dev/null || true'
  printf '[clean] Done\n' >&2
}

_clean_rootfs() {
  _docker_required
  if ! _volume_exists; then
    printf '[clean] %s does not exist — nothing to do\n' "${VOLUME_NAME}" >&2
    return 0
  fi
  printf '[clean] Removing rootfs/ subtrees from %s\n' "${VOLUME_NAME}" >&2
  _volume_exec 'find /vol -type d -name rootfs -path "*/Linux_for_Tegra/*" -exec rm -rf {} + 2>/dev/null || true'
  printf '[clean] Done\n' >&2
}

_clean_l4t() {
  _docker_required
  if ! _volume_exists; then
    printf '[clean] %s does not exist — nothing to do\n' "${VOLUME_NAME}" >&2
    return 0
  fi
  printf '[clean] Removing volume %s\n' "${VOLUME_NAME}" >&2
  if ! docker volume rm "${VOLUME_NAME}"; then
    emit_error \
      --category permission \
      --detail "docker volume rm ${VOLUME_NAME} failed — container still mounted?" \
      --action "Stop any running prepare/flash container: make stop"
    exit 1
  fi
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
