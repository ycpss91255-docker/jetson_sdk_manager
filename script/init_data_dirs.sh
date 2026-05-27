#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

DATA_DIR="${REPO_ROOT}/data"

dirs=(
  "${DATA_DIR}/nvsdkm"
  "${DATA_DIR}/downloads"
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

echo "[init] done"
