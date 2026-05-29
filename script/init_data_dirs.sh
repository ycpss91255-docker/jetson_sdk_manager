#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

DATA_DIR="${REPO_ROOT}/data"

dirs=(
  "${DATA_DIR}/jetson_l4t"
  "${DATA_DIR}/downloads"
  "${DATA_DIR}/nvsdkm"
  "${DATA_DIR}/nvidia_sdk"
)

for d in "${dirs[@]}"; do
  if [[ -d "${d}" ]]; then
    echo "[init] already exists: ${d}"
  else
    mkdir -p "${d}"
    echo "[init] created: ${d}"
  fi
done

# Warn (do not abort) if data/jetson_l4t/ landed on a filesystem that
# cannot preserve setuid + ownership. prepare.sh inside the container
# does the hard abort -- this surface-level warning catches the same
# issue earlier, before the user wastes time on a 30 minute prepare.
fstype=$(stat -f -c %T "${DATA_DIR}/jetson_l4t" 2>/dev/null || true)
case "${fstype}" in
  fuseblk|ntfs*|exfat|vfat|msdos)
    cat >&2 <<EOF
[init] WARNING: data/jetson_l4t/ is on ${fstype}.

apply_binaries.sh writes setuid binaries (sudo) and root-owned files
into the rootfs; ${fstype} strips both, which produces a Jetson whose
sudo refuses to start after flash. prepare.sh will abort with an
action message; fix it now by either:

  - Moving the repo to an ext4 / xfs / btrfs partition, or
  - Bind-mounting an ext4 directory over ./data/jetson_l4t/:
      sudo mkdir -p /var/lib/jetson_l4t
      sudo mount --bind /var/lib/jetson_l4t ./data/jetson_l4t

EOF
    ;;
esac

echo "[init] done"
