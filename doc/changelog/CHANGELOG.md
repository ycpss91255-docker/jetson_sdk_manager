# Changelog

## [Unreleased]

### Added
- **L4T data store lifecycle on non-unix checkouts (#93).** `host_setup.sh` step 0 now provisions an ext4 image *inside the repo* (`data/jetson_l4t.img`, sparse, `L4T_STORE_SIZE=40G`) and loop-mounts it over `data/jetson_l4t/` when the checkout is on NTFS / exFAT / FAT, recording the choice in `data/.l4t_store`. `L4T_STORE_DIR` opts into a bind-mounted ext4 directory instead. `host_teardown.sh` releases the mount (and removes the empty `/srv/jetson_l4t`); new `clean.sh purge` (`--keep-downloads`) deletes the store + marker for zero residue before `rm -rf <repo>`. New `script/lib/store.sh`, `test/smoke/store_lib.bats`, and a `store-loop-system` CI job that does the real loop mount. README gains a "Removing the repo" section; TEST.md documents the unit / integration / system / acceptance levels.

### Changed
- `host_setup.sh` stale-`/srv` check (#76) compares device+inode instead of `findmnt` SOURCE strings, so a loop root or a bind-of-bind no longer trips it on re-run.
- `host_setup.sh` / `host_teardown.sh` / `clean.sh` are now shellchecked and their bats suites run in `devel-test` (they used to skip).

### Removed
- The manual `sudo mount --bind /var/lib/jetson_l4t ./data/jetson_l4t` recipe from the README — it put repo data outside the repo and broke `host_setup.sh` idempotency.

- Initial release
