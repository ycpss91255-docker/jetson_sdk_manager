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

# Note (do not abort) if data/jetson_l4t/ landed on a filesystem that
# cannot preserve setuid + ownership. host_setup.sh step 0 fixes it (#93)
# by loop-mounting an in-repo ext4 image; prepare.sh inside the container
# does the hard abort if that step was skipped.
fstype=$(stat -f -c %T "${DATA_DIR}/jetson_l4t" 2>/dev/null || true)
case "${fstype}" in
  fuseblk|ntfs*|exfat|vfat|msdos)
    cat >&2 <<EOF
[init] NOTE: data/jetson_l4t/ is on ${fstype}, which cannot keep the
setuid + root-owned files apply_binaries.sh writes. Nothing to fix by
hand: ./script/host_setup.sh (step 0) will create data/jetson_l4t.img
(ext4, inside this repo) and loop-mount it over data/jetson_l4t/.
Run it before \`make run -- -t prepare\`. See README "Prerequisites".

EOF
    ;;
esac

echo "[init] done"
