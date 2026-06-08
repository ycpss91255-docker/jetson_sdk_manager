#!/usr/bin/env bash
# sdkm-entrypoint.sh — guard the data dir, then launch SDK Manager.
#
# SDK Manager (cli/gui stages) extracts the L4T rootfs — with a
# setuid `sudo` and root-owned files — under ~/nvidia/nvidia_sdk, a host
# bind mount (setup.conf → ./data/nvidia_sdk). On NTFS / exFAT / fuseblk
# hosts those attributes are stripped, exactly like the factory path,
# producing a flashed Jetson whose sudo is broken. Reuse the shared guard
# (lib/fs.sh), then exec whatever SDK Manager invocation the stage's CMD
# passes (e.g. `sdkmanager --cli`).
#
# SDK Manager also generates an SSH key under ~/.nvsdkm/.ssh (host:
# ./data/nvsdkm) and uses it to reach the booted board for the on-device
# install steps. On a non-unix FS the key is forced 0777 and ssh refuses it
# ("bad permissions" -> key ignored), so the OS flashes but the on-device
# install silently stalls (#85). Guard that dir too.
#
# Device-mode flash forwarding (iptables MASQUERADE + a DNS probe) is set
# up by SDK Manager itself; the cli/gui images ship iptables +
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

# SDK Manager's config + SSH key dir (container path; overridable for tests).
# Maps to ./data/nvsdkm on the host.
SDKM_CONF_DIR="${SDKM_CONF_DIR:-${HOME}/.nvsdkm}"

assert_unix_fs "${SDKM_CONF_DIR}" "sdkmanager" \
  --action "SDK Manager stores its SSH key under ${SDKM_CONF_DIR}/.ssh; a non-unix FS forces it 0777 and ssh refuses it, stalling the on-device install (host: ./data/nvsdkm)"

if [[ "$#" -eq 0 ]]; then
  printf 'sdkm-entrypoint.sh: no SDK Manager command given\n' >&2
  exit 2
fi

exec "$@"
