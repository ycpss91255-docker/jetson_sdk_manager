#!/usr/bin/env bash
# errors.sh — category-templated error emitter.
#
# Print a structured error that names the problem, what the user should
# do next, and where to report it if the suggested actions don't help.
# Sourced by prepare.sh / flash.sh / clean.sh and their lib/ helpers.
#
# Usage:
#   emit_error \
#     --category download \
#     --detail "HTTP 404 fetching ${url}" \
#     --action "Check supported versions in config/jetson/_l4t_mapping.yaml" \
#     --action "Verify NVIDIA archive availability: <archive-url>" \
#     --report "https://github.com/ycpss91255-docker/jetson_sdk_manager/issues"
#
# Categories steer the user toward the right doc section in README.
# Add a new category by editing _CATEGORY_HINTS below.

set -euo pipefail

# Default report URL — overridable per-call with --report.
ERRORS_REPORT_URL="${ERRORS_REPORT_URL:-https://github.com/ycpss91255-docker/jetson_sdk_manager/issues}"

declare -A _CATEGORY_HINTS=(
  [download]="Network / NVIDIA archive availability problem."
  [extract]="Tarball corrupt or filesystem cannot preserve unix attrs."
  [validate]="jetson.yaml content does not match the expected schema."
  [volume-mismatch]="Docker volume contents disagree with jetson.yaml — run a clean target."
  [permission]="Filesystem cannot preserve setuid / ownership (NTFS, exFAT) — see README."
  [hardware]="Jetson not in APX recovery or USB endpoint stale — see README."
)

emit_error() {
  local category="" detail=""
  local -a actions=()
  local report="${ERRORS_REPORT_URL}"

  while (( $# > 0 )); do
    case "$1" in
      --category) category="$2"; shift 2 ;;
      --detail) detail="$2"; shift 2 ;;
      --action) actions+=("$2"); shift 2 ;;
      --report) report="$2"; shift 2 ;;
      *) printf 'emit_error: unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if [[ -z "${category}" || -z "${detail}" ]]; then
    printf 'emit_error: --category and --detail are required\n' >&2
    return 2
  fi

  local hint="${_CATEGORY_HINTS[${category}]:-Uncategorized error.}"

  printf '\n' >&2
  printf '\033[31mError [%s]\033[0m %s\n' "${category}" "${detail}" >&2
  printf '  %s\n' "${hint}" >&2
  if (( ${#actions[@]} > 0 )); then
    printf '\nTry:\n' >&2
    local a
    for a in "${actions[@]}"; do
      printf '  - %s\n' "${a}" >&2
    done
  fi
  printf '\nIf the above does not help, report at:\n  %s\n\n' "${report}" >&2
}
