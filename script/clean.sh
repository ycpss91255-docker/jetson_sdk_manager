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
#   purge   — all + host_teardown + delete the L4T data store itself (the
#             in-repo ext4 image or the L4T_STORE_DIR bind, #93) and its
#             marker. The strongest clean: afterwards `rm -rf <repo>` leaves
#             nothing behind. `--keep-downloads` spares the tarballs.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/store.sh
. "${_HERE}/lib/store.sh"

VOLUME_NAME="${VOLUME_NAME:-jetson_l4t}"
# Overridable so the bats suite can point data/ at a tmpdir.
L4T_REPO_ROOT="${L4T_REPO_ROOT:-$(cd "${_HERE}/.." && pwd)}"
BINDMOUNT_PATH_DEFAULT="${L4T_REPO_ROOT}/data/jetson_l4t"
BINDMOUNT_PATH="${BINDMOUNT_PATH:-${BINDMOUNT_PATH_DEFAULT}}"
DOWNLOADS_HOST_DIR="${DOWNLOADS_HOST_DIR:-./data/downloads}"
HOST_TEARDOWN_BIN="${HOST_TEARDOWN_BIN:-${_HERE}/host_teardown.sh}"

_usage() {
  cat >&2 <<'EOF'
Usage: ./script/clean.sh <target> [--keep-downloads]

Targets:
  build   Remove generated flash images only (tools/kernel_flash/images/).
  rootfs  Remove rootfs/ subtree (keeps BSP).
  l4t     Wipe the L4T volume / bind mount.
  all     l4t + drop cached tarballs from data/downloads/.
  purge   all + host_teardown + delete the L4T data store (in-repo ext4
          image or L4T_STORE_DIR bind) and its marker. Zero residue: after
          this, `rm -rf <repo>` removes everything. Pass --keep-downloads
          to spare the tarballs (skips the re-download next time).

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

# _reset_phases <space-separated phase names>
#
# Drop the named phases from every .prepared.yaml marker in the volume.
# clean.sh only rm's directories; the ledger lives INSIDE the volume and
# is not touched by the surgical finds. Without this, prepare.sh's resume
# logic (volume_phase_done) and flash.sh's images gate would still treat a
# just-deleted phase as done — so a re-prepare silently regenerates nothing
# and flash then runs against missing images. alpine:3 has no yq, so use
# the yq image's bundled busybox shell to edit each marker in place.
_reset_phases() {
  local phases="$1" mount_spec
  if ! mount_spec=$(_resolve_mount_spec); then
    return 0
  fi
  docker run --rm --entrypoint /bin/sh -v "${mount_spec}" mikefarah/yq:4 -c '
    drop="'"${phases}"'"
    find /vol -type f -name .prepared.yaml | while IFS= read -r m; do
      for p in ${drop}; do
        yq -i "del(.phases[] | select(. == \"${p}\"))" "${m}"
      done
      echo "[clean] reset phases (${drop}) in ${m}" >&2
    done
  '
}

# Echo "removed N path(s)" / "nothing matched" instead of an unconditional
# "Done", and drop the blanket 2>/dev/null so real errors (permission,
# mount) abort under set -e rather than masquerading as a clean run.
_clean_build() {
  _docker_required
  printf '[clean] Removing tools/kernel_flash/images/\n' >&2
  _volume_exec '
    matches=$(find /vol -type d -name images -path "*/tools/kernel_flash/*")
    if [ -z "${matches}" ]; then
      echo "[clean] nothing matched — already clean?" >&2
    else
      printf "%s\n" "${matches}" | xargs rm -rf
      echo "[clean] removed $(printf "%s\n" "${matches}" | wc -l) image dir(s)" >&2
    fi
  '
  # Images are gone — clear the phase so re-prepare regenerates them and
  # flash.sh no longer passes its "images" gate against a missing dir.
  _reset_phases "images"
}

_clean_rootfs() {
  _docker_required
  printf '[clean] Removing rootfs/ subtrees\n' >&2
  _volume_exec '
    matches=$(find /vol -type d -name rootfs -path "*/Linux_for_Tegra/*")
    if [ -z "${matches}" ]; then
      echo "[clean] nothing matched — already clean?" >&2
    else
      printf "%s\n" "${matches}" | xargs rm -rf
      echo "[clean] removed $(printf "%s\n" "${matches}" | wc -l) rootfs subtree(s)" >&2
    fi
  '
  # Removing rootfs/ invalidates everything layered on top of it: the
  # applied binaries, the created user, the static-network profile, and
  # the generated images all live under (or were derived from) rootfs.
  _reset_phases "rootfs binaries user network images"
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

# _purge_store — delete the store recorded in data/.l4t_store (#93). Runs
# AFTER _clean_l4t emptied the mounted tree and host_teardown unmounted it,
# so for a directory-bind store only an `rmdir` is left — never `rm -rf` a
# path read from a file. The marker must pass store_marker_validate first.
_purge_store() {
  local marker backend target
  store_paths "${L4T_REPO_ROOT}"
  marker="${STORE_MARKER}"
  if [[ ! -f "${marker}" ]]; then
    printf '[clean] no store marker at %s — native checkout, nothing to purge\n' "${marker}" >&2
    return 0
  fi
  store_marker_validate "${marker}" "${L4T_REPO_ROOT}" || {
    emit_error \
      --category permission \
      --detail "refusing to purge: ${marker} did not validate (see above)" \
      --action "If this checkout was moved or the marker is stale, inspect it and remove it by hand" \
      --action "Never delete the store path from a marker you do not trust"
    exit 1
  }
  backend="$(store_marker_read "${marker}" backend)"
  case "${backend}" in
    loop-image)
      target="$(store_marker_read "${marker}" image)"
      printf '[clean] Deleting ext4 image %s\n' "${target}" >&2
      rm -f "${target}"
      ;;
    directory-bind)
      target="$(store_marker_read "${marker}" store)"
      if [[ -n "$(ls -A "${target}" 2>/dev/null)" ]]; then
        emit_error \
          --category permission \
          --detail "directory-bind store ${target} is not empty after clean + teardown" \
          --action "Check it is unmounted (findmnt ${target}) and empty it yourself, then re-run purge"
        exit 1
      fi
      printf '[clean] Removing empty store directory %s\n' "${target}" >&2
      rmdir "${target}"
      ;;
  esac
  rm -f "${marker}"
  printf '[clean] removed marker %s\n' "${marker}" >&2
}

_clean_purge() {
  local keep_downloads="$1"
  store_paths "${L4T_REPO_ROOT}"
  # Same fail-closed rule as host_setup.sh: a mount we did not record is not
  # ours to empty or unmount (#93 review). Checked before ANY destructive step.
  if [[ ! -f "${STORE_MARKER}" ]] && "${MOUNTPOINT_BIN:-mountpoint}" -q "${BINDMOUNT_PATH}"; then
    emit_error \
      --category host-config \
      --detail "${BINDMOUNT_PATH} is a mountpoint of unknown origin and there is no data/.l4t_store marker — refusing to purge through it" \
      --action "If you mounted an ext4 directory there yourself: sudo umount ${BINDMOUNT_PATH}, then purge" \
      --action "If host_setup.sh set it up, its marker is missing — re-run ./script/host_setup.sh first (it recovers the marker)"
    exit 1
  fi
  if [[ ! -f "${STORE_MARKER}" ]] \
      && ! docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1 \
      && [[ -z "$(ls -A "${BINDMOUNT_PATH}" 2>/dev/null)" ]]; then
    printf '[clean] nothing to purge — no store marker, volume or L4T content\n' >&2
    # Still make sure the host is back to normal (idempotent).
    "${HOST_TEARDOWN_BIN}"
    return 0
  fi
  printf '[clean] purge will remove: L4T tree, host mounts' >&2
  [[ -n "${keep_downloads}" ]] || printf ', cached tarballs in %s' "${DOWNLOADS_HOST_DIR}" >&2
  [[ -f "${STORE_MARKER}" ]] && printf ', store %s' \
    "$(store_marker_read "${STORE_MARKER}" image 2>/dev/null || store_marker_read "${STORE_MARKER}" store 2>/dev/null || true)" >&2
  printf '\n' >&2
  # Validate BEFORE any destructive step so a foreign marker aborts with the
  # tree, tarballs and mounts untouched.
  if [[ -f "${STORE_MARKER}" ]]; then
    store_marker_validate "${STORE_MARKER}" "${L4T_REPO_ROOT}" || exit 1
  fi
  if [[ -n "${keep_downloads}" ]]; then
    _clean_l4t
  else
    _clean_all
  fi
  "${HOST_TEARDOWN_BIN}"
  _purge_store
}

main() {
  local target="${1:-}" keep_downloads=""
  shift || true
  for arg in "$@"; do
    case "${arg}" in
      --keep-downloads) keep_downloads=yes ;;
      *) printf 'clean.sh: unknown option: %s\n\n' "${arg}" >&2; _usage; exit 2 ;;
    esac
  done
  case "${target}" in
    build) _clean_build ;;
    rootfs) _clean_rootfs ;;
    l4t) _clean_l4t ;;
    all) _clean_all ;;
    purge) _clean_purge "${keep_downloads}" ;;
    -h|--help|"") _usage; exit 0 ;;
    *) printf 'clean.sh: unknown target: %s\n\n' "${target}" >&2; _usage; exit 2 ;;
  esac
}

main "$@"
