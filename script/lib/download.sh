#!/usr/bin/env bash
# download.sh — wget BSP / rootfs tarballs with skip-if-present semantics.
#
# Idempotent: an existing local file with non-zero size is considered
# present and skipped. NVIDIA does not publish per-file checksums for
# the L4T archive, so size+existence is the strongest signal a downstream
# script can use without round-tripping to a release index. If a partial
# download is suspected, delete the file in `data/downloads/` and rerun.

set -euo pipefail

# Caller must have already sourced errors.sh.
if ! declare -F emit_error >/dev/null; then
  printf 'download.sh: emit_error not defined — source errors.sh first\n' >&2
  return 1
fi

DOWNLOADS_DIR="${DOWNLOADS_DIR:-${HOME}/Downloads/nvidia/sdkm_downloads}"

# download_if_missing <url> [out_basename]
# Downloads `url` to ${DOWNLOADS_DIR}/<out_basename> (defaults to the
# url's basename). Skips silently if the file already exists with
# non-zero size. Echoes the resolved path to stdout.
download_if_missing() {
  local url="$1"
  local basename="${2:-$(basename "${url}")}"
  local out="${DOWNLOADS_DIR}/${basename}"

  mkdir -p "${DOWNLOADS_DIR}"

  if [[ -s "${out}" ]]; then
    printf '%s' "${out}"
    return 0
  fi

  printf '[download] %s\n' "${url}" >&2
  if ! wget --quiet --show-progress --output-document="${out}.partial" "${url}"; then
    rm -f "${out}.partial"
    emit_error \
      --category download \
      --detail "wget failed for ${url}" \
      --action "Check network connectivity from inside the container" \
      --action "Verify URL availability at https://developer.nvidia.com/embedded/jetson-linux-archive" \
      --action "If behind a proxy, set http_proxy/https_proxy in setup.conf [environment]"
    return 1
  fi
  mv "${out}.partial" "${out}"
  printf '%s' "${out}"
}
