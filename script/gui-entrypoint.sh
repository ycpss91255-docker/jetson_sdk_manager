#!/usr/bin/env bash
# gui-entrypoint.sh — launch the SDK Manager GUI with a best-effort banner.
#
# The `gui` stage ships SDK Manager's graphical client as a best-effort
# flashing path (and JetPack catalog browser). It is NOT the supported
# default: the CI-guarded factory workflow (prepare + flash stages) is.
#
# Earlier revisions claimed the GUI's Install/flash button was
# "fundamentally broken inside Docker". That was disproved: the mid-flash
# stall was the host's NetworkManager DHCP-ing the USB gadget link (#48 /
# #49, fixed by nm_flash_guard.sh), and the "Device mode forwarding host
# setup failed" step was just missing iptables + dnsutils in the image
# (#51, now in sdkm-base). With those in place and an NVIDIA login, the GUI
# can complete a flash — best-effort, since it may drift with NVIDIA
# upstream and is not exercised by CI beyond `sdkmanager --ver`.
#
# Prerequisites for a GUI flash (all host-side, before launching):
#   ./script/host_setup.sh            # qemu + nfsd + USB tweaks + /srv bridge
#   ./script/nm_flash_guard.sh auto   # keep NetworkManager off the USB link
#   an NVIDIA Developer login in the GUI
#
# The SDK Manager data dir guard (non-unix FS → broken setuid) is shared
# with the cli path via sdkm-entrypoint.sh, which this delegates to.

set -euo pipefail

# shellcheck disable=SC2155
readonly BOLD=$(tput bold 2>/dev/null || true)
# shellcheck disable=SC2155
readonly CYAN=$(tput setaf 6 2>/dev/null || true)
# shellcheck disable=SC2155
readonly YELLOW=$(tput setaf 3 2>/dev/null || true)
# shellcheck disable=SC2155
readonly RESET=$(tput sgr0 2>/dev/null || true)

print_banner() {
  printf '%s\n' \
    '' \
    "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" \
    "${CYAN}${BOLD}  GUI MODE — SDK Manager (best-effort flash + catalog browser)${RESET}" \
    "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" \
    '' \
    "${BOLD}Supported default is factory flash:${RESET}" \
    '    make run -- -t prepare     # downloads BSP + builds flash images' \
    '    make run -- -t flash       # writes images to a Jetson in APX recovery' \
    '' \
    "${YELLOW}For a GUI flash (best-effort), first do these on the host:${RESET}" \
    '    ./script/host_setup.sh             # qemu + nfsd + USB + /srv bridge' \
    '    ./script/nm_flash_guard.sh auto    # keep NetworkManager off the link' \
    '  then sign in with your NVIDIA Developer account in the GUI.' \
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
    'Pick the matching JetPack release in the GUI.' \
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
  # Delegate the non-unix-FS data-dir guard to the shared launcher, then
  # hand off to the GUI binary.
  exec /opt/jetson_install/sdkm-entrypoint.sh \
    /opt/nvidia/sdkmanager/sdkmanager-gui --no-sandbox "$@"
}

main "$@"
