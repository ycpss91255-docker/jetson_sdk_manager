#!/usr/bin/env bash
# sdkm-entrypoint.sh — guard the data dir, then launch SDK Manager.
#
# SDK Manager (cli/inspector stages) extracts the L4T rootfs — with a
# setuid `sudo` and root-owned files — under ~/nvidia/nvidia_sdk, a host
# bind mount (setup.conf → ./data/nvidia_sdk). On NTFS / exFAT / fuseblk
# hosts those attributes are stripped, exactly like the factory path,
# producing a flashed Jetson whose sudo is broken. Reuse the shared guard
# (lib/fs.sh), then exec whatever SDK Manager invocation the stage's CMD
# passes (e.g. `sdkmanager --cli`).
#
# Device-mode flash forwarding (iptables MASQUERADE + a DNS probe) is set
# up by SDK Manager itself; the cli/inspector images ship iptables +
# dnsutils so that step no longer fails. NetworkManager handling for the
# USB flash link is a host-side concern — see script/nm_flash_guard.sh.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
. "${_HERE}/lib/errors.sh"
# shellcheck source=lib/fs.sh
. "${_HERE}/lib/fs.sh"

# Where SDK Manager extracts the flashable tree (container path; overridable
# for tests). Maps to ./data/nvidia_sdk on the host.
SDKM_DATA_DIR="${SDKM_DATA_DIR:-${HOME}/nvidia/nvidia_sdk}"

assert_unix_fs "${SDKM_DATA_DIR}" "sdkmanager" \
  --action "SDK Manager extracts the flashable L4T rootfs under ${SDKM_DATA_DIR} (host: ./data/nvidia_sdk)"

if [[ "$#" -eq 0 ]]; then
  printf 'sdkm-entrypoint.sh: no SDK Manager command given\n' >&2
  exit 2
fi

exec "$@"
