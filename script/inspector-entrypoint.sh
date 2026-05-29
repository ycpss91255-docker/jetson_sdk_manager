#!/usr/bin/env bash
# inspector-entrypoint.sh — launch SDK Manager GUI with a warning banner.
#
# SDK Manager's GUI is kept in this image as a catalog browser (for
# inspecting which .deb packages a given JetPack release ships, or
# pulling individual debs by hand). Its "Install" button is
# fundamentally broken inside Docker: it needs an NFS server,
# iptables manipulation, and USB device-mode forwarding -- none of
# which work reliably in a container, even with `--privileged
# --network host`. Confirmed broken on NVIDIA's own Docker image too.
#
# The production flash path lives in the prepare + flash stages.
# This entrypoint prints a banner naming that path before launching,
# and (when run interactively) prompts for Enter so the user has to
# explicitly acknowledge before the GUI appears.

set -euo pipefail

# shellcheck disable=SC2155
readonly BOLD=$(tput bold 2>/dev/null || true)
# shellcheck disable=SC2155
readonly RED=$(tput setaf 1 2>/dev/null || true)
# shellcheck disable=SC2155
readonly YELLOW=$(tput setaf 3 2>/dev/null || true)
# shellcheck disable=SC2155
readonly RESET=$(tput sgr0 2>/dev/null || true)

print_banner() {
  printf '%s\n' \
    '' \
    "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" \
    "${RED}${BOLD}  INSPECTOR MODE — SDK Manager GUI for catalog browsing only${RESET}" \
    "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" \
    '' \
    "${YELLOW}The Install (flash) button does not work inside Docker:${RESET}" \
    '  - NFS server / iptables manipulation unavailable in containers' \
    '  - USB device-mode forwarding fails under --privileged --network host' \
    '' \
    "${BOLD}To flash a Jetson, use the factory-flash workflow instead:${RESET}" \
    '    make run -- -t prepare     # downloads BSP + builds flash images' \
    '    make run -- -t flash       # writes images to a Jetson in APX recovery' \
    '' >&2
}

print_jetson_yaml_hint() {
  [[ -f /etc/jetson.yaml ]] || return 0
  command -v yq >/dev/null 2>&1 || return 0

  local jp board
  jp=$(yq -r '.jetpack.version // ""' /etc/jetson.yaml 2>/dev/null || true)
  board=$(yq -r '.hardware.board // ""' /etc/jetson.yaml 2>/dev/null || true)

  [[ -z "${jp}" && -z "${board}" ]] && return 0

  printf '%s\n' \
    "${BOLD}Your jetson.yaml selects:${RESET}" \
    "  JetPack: ${jp:-<unset>}" \
    "  Board:   ${board:-<unset>}" \
    'Pick the matching JetPack release in the GUI if you are looking up' \
    'packages for this device.' \
    '' >&2
}

wait_for_ack() {
  [[ -t 0 && -t 1 ]] || return 0
  printf '%sPress Enter to launch SDK Manager GUI, or Ctrl-C to abort:%s ' \
    "${BOLD}" "${RESET}" >&2
  read -r _
}

main() {
  print_banner
  print_jetson_yaml_hint
  wait_for_ack
  exec /opt/nvidia/sdkmanager/sdkmanager-gui --no-sandbox "$@"
}

main "$@"
