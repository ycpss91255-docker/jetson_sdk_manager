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

# _verify_download <file> <expected_sha256>
# Integrity gate run on a freshly-downloaded file BEFORE it is moved into
# place. Two-tier:
#   1. If a sha256 is supplied (from _l4t_mapping.yaml bsp_sha256 /
#      rootfs_sha256), require an exact match. This catches a silently
#      truncated transfer or a tampered mirror.
#   2. Otherwise fall back to a magic-byte sniff: the L4T BSP / rootfs are
#      bzip2-compressed tarballs, so the first three bytes must be `BZh`.
#      This is the cheapest way to catch the common failure mode where a CDN
#      / proxy returns an HTML error page (saved as the "tarball") or a
#      zero/short file — `tar` would otherwise die much later with an opaque
#      message. NVIDIA does not publish per-file checksums, hence the fallback.
# Emits a download-category error and returns non-zero on failure.
_verify_download() {
  local file="$1" expected="${2:-}"

  if [[ -n "${expected}" ]]; then
    local actual
    actual=$(sha256sum "${file}" 2>/dev/null | awk '{print $1}')
    if [[ "${actual}" != "${expected}" ]]; then
      emit_error \
        --category download \
        --detail "sha256 mismatch for ${file##*/} (expected ${expected}, got ${actual:-none})" \
        --action "Delete the file and re-download — the transfer was truncated or the mirror is wrong" \
        --action "If this persists, confirm the checksum in _l4t_mapping.yaml against NVIDIA's release page"
      return 1
    fi
    return 0
  fi

  # No checksum available — sniff the bzip2 tarball magic so a saved error
  # page / truncated download is caught before tar chokes on it downstream.
  local magic
  magic=$(head -c 3 "${file}" 2>/dev/null || true)
  if [[ "${magic}" != "BZh" ]]; then
    emit_error \
      --category download \
      --detail "Downloaded ${file##*/} is not a bzip2 tarball (magic '${magic}' != 'BZh') — likely a saved error page or a truncated download" \
      --action "Delete the file in data/downloads/ and re-run" \
      --action "Verify URL availability at https://developer.nvidia.com/embedded/jetson-linux-archive" \
      --action "If behind a proxy, confirm it is not returning an HTML interstitial for the download"
    return 1
  fi
}

# download_if_missing <url> [out_basename] [expected_sha256]
# Downloads `url` to ${DOWNLOADS_DIR}/<out_basename> (defaults to the
# url's basename). Skips silently if the file already exists with
# non-zero size. Verifies integrity (sha256 if given, else bzip2 magic)
# before accepting the file. Echoes the resolved path to stdout.
download_if_missing() {
  local url="$1"
  local basename="${2:-$(basename "${url}")}"
  local expected_sha256="${3:-}"
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
  # Integrity-gate the .partial before promoting it: a failed check leaves no
  # half-trusted file behind for the skip-if-present branch to pick up next run.
  if ! _verify_download "${out}.partial" "${expected_sha256}"; then
    rm -f "${out}.partial"
    return 1
  fi
  mv "${out}.partial" "${out}"
  printf '%s' "${out}"
}
