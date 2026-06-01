#!/usr/bin/env bash
# probe.sh — Jetson USB diagnostic. Standalone alternative to running
# `flash.sh` just to see whether the Jetson is detected.
#
# Lists every NVIDIA-vendor (0955) USB device currently on the bus,
# annotates each with whether its product ID matches the known Tegra
# recovery range (see script/lib/usb.sh::JETSON_RECOVERY_PIDS), and
# exits 0 only when at least one recovery device is present.
#
# Run via:  make run -- -t probe
#
# No Jetson required at image-build time. No jetson.yaml needed at
# runtime — probe is intentionally config-free so users can sanity-
# check the host ↔ Jetson link before they've configured anything.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/usb.sh
. "${_HERE}/lib/usb.sh"

_step()    { printf '\n\033[36m[probe] %s\033[0m\n' "$1" >&2; }
_ok()      { printf '  \033[32m✓\033[0m %s\n' "$1" >&2; }
_warn()    { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }
_info()    { printf '    %s\n' "$1" >&2; }

main() {
  _step "Scanning USB for NVIDIA vendor 0x${JETSON_USB_VENDOR}"

  local devices recovery_count=0 nonrecovery_count=0 pid line
  devices=$(jetson_list_devices)

  if [[ -z "${devices}" ]]; then
    printf '  (no devices)\n' >&2
    cat >&2 <<EOF

[probe] No NVIDIA USB device detected.

To put the Jetson into APX recovery:
  1. Disconnect power.
  2. Connect USB-C between the Jetson front panel (button side) and the host.
  3. Hold Force-Recovery (REC).
  4. Reconnect power (or press Power).
  5. Release REC after ~2 seconds.

Then re-run \`make run -- -t probe\` to verify.
EOF
    exit 1
  fi

  while IFS=$'\t' read -r pid line; do
    if jetson_pid_is_recovery "${pid}"; then
      _ok "${line}"
      _info "PID ${pid} is in the Orin APX recovery range — ready to flash."
      recovery_count=$((recovery_count + 1))
    else
      _warn "${line}"
      _info "PID ${pid} is NVIDIA-vendor but NOT in the recovery range — likely a Jetson booted into the OS."
      nonrecovery_count=$((nonrecovery_count + 1))
    fi
  done <<<"${devices}"

  printf '\n' >&2
  printf '[probe] Summary: %d in recovery, %d on bus but not in recovery.\n' \
    "${recovery_count}" "${nonrecovery_count}" >&2

  if (( recovery_count == 0 )); then
    cat >&2 <<EOF

[probe] No Jetson in APX recovery — flash will not start.

Action:
  1. Power-cycle the Jetson into recovery: power off, hold REC, reconnect power, release REC.
  2. Re-run \`make run -- -t probe\` to verify the new PID lands in the recovery range.
EOF
    exit 1
  fi

  printf '\n[probe] At least one Jetson is in APX recovery. Next: \`make run -- -t flash\`.\n' >&2
}

main "$@"
