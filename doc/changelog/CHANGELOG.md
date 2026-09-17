# Changelog

## [Unreleased]

### Added
- **`usb_ss_guard.sh` — park the SuperSpeed half of the Jetson's connector during the initrd flash (#100).** On some hosts the flash initrd's gadget (`0955:7035`) never trains its SuperSpeed link and the xHCI retries tear the working USB 2 device down every few seconds (`Waiting for target to boot-up...` until timeout, dmesg `Cannot enable. Maybe the USB cable is bad?`). `disable` pairs the recovery device's root-hub port with the single SuperSpeed root-hub port sharing its ACPI `location` and writes `disable=1` there, recording it in root-owned `/run/usb-ss-guard/` (both roots are literal constants; `USB_SS_GUARD_TEST_ROOT` is the only, explicit, sudo-free override for tests); `enable` re-validates that path (root-hub port shape, no symlinks) and restores exactly it; `auto` starts a root watcher (`sudo -n`, own pidfile, per-disable token, kills only verified watchers) that re-enables on boot (`0955:7020`) or timeout. `./jetson flash` runs it after the NM guard, `host_teardown.sh` step 6/6 re-enables, `./jetson status` warns while a port is parked. README prerequisites bullet + TROUBLESHOOTING entry with the dmesg signature and the manual `echo 1 | sudo tee .../usbN-portM/disable` fallback. `test/smoke/usb_ss_guard.bats` (sysfs fixture tree).
- **`./jetson` — one entry point for the whole flash workflow (#95).** `status` (one-page host readiness + Jetson USB state, ✔ / ⚠ / ✘), `prepare` (host setup + BSP download + image build), `wait-rec`, `flash` (recovery + prepare preflight, NetworkManager guard, ssh hint), `all`, `teardown`, `purge [--yes] [--keep-downloads]`. Thin dispatcher over the existing scripts (`script/jetson.sh`, `script/lib/status.sh`); every step remains runnable by hand.
- **README rewritten around `./jetson`**: three-command quick start, an "Entering recovery (REC) mode" section with a button-panel diagram and the USB-ID table, "After the flash". Stages / flashing paths / SDK Manager / persistent data / build graph / directory layout moved to `doc/ARCHITECTURE.md`; every troubleshooting entry moved to `doc/TROUBLESHOOTING.md`. zh-TW rewritten to match; zh-CN / ja carry a banner pointing at the new flow.
- **L4T data store lifecycle on non-unix checkouts (#93).** `host_setup.sh` step 0 now provisions an ext4 image *inside the repo* (`data/jetson_l4t.img`, sparse, `L4T_STORE_SIZE=40G`) and loop-mounts it over `data/jetson_l4t/` when the checkout is on NTFS / exFAT / FAT, recording the choice in `data/.l4t_store`. `L4T_STORE_DIR` opts into a bind-mounted ext4 directory instead. `host_teardown.sh` releases the mount (and removes the empty `/srv/jetson_l4t`); new `clean.sh purge` (`--keep-downloads`) deletes the store + marker for zero residue before `rm -rf <repo>`. New `script/lib/store.sh`, `test/smoke/store_lib.bats`, and a `store-loop-system` CI job that does the real loop mount. README gains a "Removing the repo" section; TEST.md documents the unit / integration / system / acceptance levels.

### Changed
- `host_setup.sh` stale-`/srv` check (#76) compares device+inode instead of `findmnt` SOURCE strings, so a loop root or a bind-of-bind no longer trips it on re-run.
- `host_setup.sh` / `host_teardown.sh` / `clean.sh` are now shellchecked and their bats suites run in `devel-test` (they used to skip).

### Removed
- The manual `sudo mount --bind /var/lib/jetson_l4t ./data/jetson_l4t` recipe from the README — it put repo data outside the repo and broke `host_setup.sh` idempotency.

- Initial release
