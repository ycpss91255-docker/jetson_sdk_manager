#!/usr/bin/env bash
# store_loop_system.sh — SYSTEM + ACCEPTANCE test for the L4T data-store
# lifecycle (#93): real `sudo mount -o loop`, real loop device, real inodes.
#
# The bats suites stub mount / mkfs / docker and therefore only prove the
# scripts *call* the right things. This script proves the kernel does what
# the README promises: an ext4 image inside the checkout loop-mounts over
# data/jetson_l4t, keeps setuid + ownership, is bridged to /srv/jetson_l4t
# by identity, tears down cleanly, and `clean.sh purge` leaves the host with
# zero residue so `rm -rf <clone>` removes everything.
#
# Needs root for mount / losetup (CI: ubuntu-latest has passwordless sudo).
# Runs against a throw-away COPY of the repo in a tmpdir, never the checkout
# it is launched from. Forces the loop-image backend because the runner's
# filesystem is ext4 (the fstype trigger is covered by the bats suite).
#
# Usage: test/system/store_loop_system.sh            (from the repo root)

set -euo pipefail

_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
_ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
# _check <msg> <command...> — runs a real command (no [[ ]], no ! — those are
# shell syntax, not commands). Use the helpers below for negation / globs.
_check() { local msg="$1"; shift; if "$@"; then _ok "${msg}"; else _fail "${msg}"; fi; }
_not()  { ! "$@"; }
# shellcheck disable=SC2053  # glob matching on the RHS is the point
_glob() { [[ "$1" == $2 ]]; }         # _glob <string> <pattern>
_eq()   { [ "$1" = "$2" ]; }
_no_loop_ref() { ! sudo losetup -a | grep -q "$1"; }   # no loop device backed by a path under $1
_section() { printf '\n\033[36m[system] %s\033[0m\n' "$1"; }

# ── capability probe: never let a runner without loop support pass silently
_section "capability probe"
if ! sudo -n true 2>/dev/null; then
  printf 'SKIP: passwordless sudo is required for a real loop mount\n'; exit 0
fi
if ! sudo losetup -f >/dev/null 2>&1; then
  printf 'SKIP: no free loop device on this host\n'; exit 0
fi
for t in truncate mkfs.ext4 mount umount mountpoint findmnt losetup; do
  command -v "${t}" >/dev/null || { printf 'SKIP: %s missing\n' "${t}"; exit 0; }
done
# clean.sh purge empties the store through a transient alpine container; that
# is part of the contract under test, so Docker is a hard requirement here —
# no silent fallback that would make the acceptance claim hollow.
if ! docker info >/dev/null 2>&1; then
  printf 'SKIP: docker daemon not reachable (clean.sh needs it)\n'; exit 0
fi
docker image inspect alpine:3 >/dev/null 2>&1 || docker pull -q alpine:3 >/dev/null
_ok "sudo + loop + e2fsprogs + docker available"

# ── fixture: throw-away clone, isolated /srv path, sysfs redirected
WORK="$(mktemp -d)"
CLONE="${WORK}/clone"
cp -a "${_REPO}" "${CLONE}"
rm -rf "${CLONE}/data"
mkdir -p "${CLONE}/data/downloads"
touch "${CLONE}/data/downloads/Jetson_Linux_r36.5.0_aarch64.tbz2"
export L4T_EXPORT_DIR="${WORK}/srv/jetson_l4t"
export USBCORE_PARAMS="${WORK}/usbcore"; mkdir -p "${USBCORE_PARAMS}"
: >"${USBCORE_PARAMS}/autosuspend"; : >"${USBCORE_PARAMS}/usbfs_memory_mb"
export DOCKER_BIN=__no_docker_here__        # skip the qemu pull; not under test
export NM_GUARD_BIN="${WORK}/nm_stub.sh"; printf '#!/bin/sh\nexit 0\n' >"${NM_GUARD_BIN}"; chmod +x "${NM_GUARD_BIN}"
export L4T_STORE_BACKEND=loop-image L4T_STORE_SIZE=256M L4T_STORE_MIN_SIZE=256M
DATA="${CLONE}/data/jetson_l4t"; IMG="${CLONE}/data/jetson_l4t.img"; MARKER="${CLONE}/data/.l4t_store"

cleanup() {
  # Belt and braces so a failed run never leaks a mount into the runner —
  # but never rm -rf THROUGH a mount that refused to go: that is exactly the
  # failure mode the README warns about. Keep WORK for diagnosis instead.
  local rc=$? leaked=0
  sudo umount "${L4T_EXPORT_DIR}" 2>/dev/null || true
  sudo umount "${DATA}" 2>/dev/null || true
  for m in "${L4T_EXPORT_DIR}" "${DATA}"; do
    if mountpoint -q "${m}" 2>/dev/null; then
      printf '[system] cleanup: %s is STILL mounted — leaving %s in place\n' "${m}" "${WORK}" >&2
      leaked=1
    fi
  done
  if [ -f "${IMG}" ] && [ -n "$(sudo losetup -j "${IMG}" 2>/dev/null)" ]; then
    printf '[system] cleanup: a loop device is still attached to %s\n' "${IMG}" >&2
    leaked=1
  fi
  if [ "${leaked}" -eq 0 ]; then
    sudo rm -rf "${WORK}"
  else
    rc=1
  fi
  exit "${rc}"
}
trap cleanup EXIT

cd "${CLONE}"

# ── setup
_section "host_setup.sh provisions + mounts the in-repo ext4 image"
bash ./script/host_setup.sh
_check "image exists inside the clone"          test -f "${IMG}"
_check "marker written"                          test -f "${MARKER}"
_check "marker says loop-image"                  grep -qx 'backend=loop-image' "${MARKER}"
_check "data/jetson_l4t is an ext4 mount"        _eq "$(findmnt -n -o FSTYPE "${DATA}")" ext4
_check "mount is backed by a loop device"        _glob "$(findmnt -n -o SOURCE "${DATA}")" '/dev/loop*'
_check "loop device points at the image"         test -n "$(sudo losetup -j "${IMG}")"
_check "mount root owned by the invoking user"   _eq "$(stat -c %u "${DATA}")" "$(id -u)"
_check "/srv bridge is a mountpoint"             mountpoint -q "${L4T_EXPORT_DIR}"
_check "/srv and store root share device+inode"  _eq "$(stat -c %d:%i "${L4T_EXPORT_DIR}")" "$(stat -c %d:%i "${DATA}")"

_section "unix semantics survive on the store (what NTFS could not do)"
sudo touch "${DATA}/setuid-fixture"; sudo chown 0:0 "${DATA}/setuid-fixture"; sudo chmod 4755 "${DATA}/setuid-fixture"
_check "setuid bit preserved (4755)"             _eq "$(stat -c %a "${DATA}/setuid-fixture")" 4755
_check "root ownership preserved"                _eq "$(stat -c %u:%g "${DATA}/setuid-fixture")" 0:0
_check "same file visible through /srv"          test -f "${L4T_EXPORT_DIR}/setuid-fixture"

_section "host_setup.sh is idempotent"
mtime_before="$(stat -c %Y "${IMG}")"
bash ./script/host_setup.sh
_check "second run leaves the image untouched"   _eq "$(stat -c %Y "${IMG}")" "${mtime_before}"
_check "fixture still there (no re-mkfs)"        test -f "${DATA}/setuid-fixture"

# ── teardown
_section "host_teardown.sh releases mounts, keeps data"
bash ./script/host_teardown.sh
_check "/srv unmounted"                          _not mountpoint -q "${L4T_EXPORT_DIR}"
_check "/srv directory removed (was empty)"      _not test -e "${L4T_EXPORT_DIR}"
_check "store unmounted"                         _not mountpoint -q "${DATA}"
_check "loop device detached"                    test -z "$(sudo losetup -j "${IMG}")"
_check "image kept"                              test -f "${IMG}"
_check "marker kept"                             test -f "${MARKER}"
sudo mount -o loop "${IMG}" "${DATA}"
_check "image re-mountable with data intact"     test -f "${DATA}/setuid-fixture"
sudo umount "${DATA}"

# ── purge (acceptance: zero residue)
_section "clean.sh purge — zero residue"
bash ./script/host_setup.sh >/dev/null                # bring it back up so purge has real mounts to drop
bash ./script/clean.sh purge
_check "image deleted"                           _not test -e "${IMG}"
_check "marker deleted"                          _not test -e "${MARKER}"
_check "tarballs deleted"                        _not test -e "${CLONE}/data/downloads/Jetson_Linux_r36.5.0_aarch64.tbz2"
_check "store unmounted"                         _not mountpoint -q "${DATA}"
_check "/srv gone"                               _not test -e "${L4T_EXPORT_DIR}"
_check "no loop device references the clone"    _no_loop_ref "${CLONE}"
_check "no mount references the clone"          _not grep -q "${CLONE}" /proc/self/mountinfo
_check "purge again is a no-op (exit 0)"        bash ./script/clean.sh purge
cd "${WORK}"
_check "rm -rf <clone> succeeds"                 rm -rf "${CLONE}"
_check "clone is gone"                           _not test -e "${CLONE}"

_section "purge --keep-downloads"
cp -a "${_REPO}" "${CLONE}"; rm -rf "${CLONE}/data"; mkdir -p "${CLONE}/data/downloads"
touch "${CLONE}/data/downloads/Jetson_Linux_r36.5.0_aarch64.tbz2"
cd "${CLONE}"
bash ./script/host_setup.sh >/dev/null
bash ./script/clean.sh purge --keep-downloads
_check "image deleted"                           _not test -e "${IMG}"
_check "tarball kept"                            test -e "${CLONE}/data/downloads/Jetson_Linux_r36.5.0_aarch64.tbz2"
cd "${WORK}"

printf '\n[system] %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
