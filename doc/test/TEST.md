# TEST.md

**1 test** total.

## test/smoke/orin_install_env.bats (1)

| Test | Description |
|------|-------------|
| `entrypoint.sh exists and is executable` | Entrypoint check |

## Test levels (ISTQB) for the L4T data-store lifecycle (#93)

The store lifecycle (`host_setup.sh` step 0 → `host_teardown.sh` → `clean.sh purge`, all on `script/lib/store.sh`) is the one feature with all four levels wired up. Use it as the template for the next one.

| Level | Where | What it proves | Runs in |
|---|---|---|---|
| **Unit** | `test/smoke/store_lib.bats` | `store.sh` functions in isolation: backend matrix (fstype / `L4T_STORE_DIR` / `L4T_STORE_BACKEND`), marker write is atomic + round-trips, `store_marker_validate` refuses foreign `repo_id`, unknown backend / version, relative or symlinked paths, `/`, `$HOME`, in-repo stores; size parsing (M/G, 20G floor, never shrink); device+inode identity. | `devel-test` stage (`make build test`) |
| **Integration** | `test/smoke/host_setup.bats`, `host_teardown.bats`, `clean_targets.bats` | The three CLIs drive the right tools in the right order, with `mount` / `mkfs.ext4` / `chown` / `docker` / `host_teardown.sh` stubbed on PATH: first run creates + formats + loop-mounts + writes the marker; re-run neither re-formats nor re-mounts; missing `mkfs.ext4` aborts before creating anything; `/srv` bound elsewhere fails safely; teardown unmounts `/srv` then the store and `rmdir`s only an empty `/srv`; `purge` = `all` + teardown + delete, `--keep-downloads`, idempotent, refuses a foreign / malformed marker without deleting. | `devel-test` stage |
| **System** | `test/system/store_loop_system.sh` | The kernel does what the scripts promise: a real `sudo mount -o loop` of an in-repo ext4 image, setuid + root ownership survive on it, `/srv/jetson_l4t` and the store root share device+inode, teardown detaches the loop device and the image re-mounts with its data. | `store-loop-system` CI job (ubuntu-latest, sudo). Skips with a reason if the runner lacks sudo / loop. |
| **Acceptance** | same script, final sections | The README's user-facing contract: after `clean.sh purge`, image + marker + tarballs are gone, no mount or loop device references the clone, `purge` again exits 0, and `rm -rf <clone>` succeeds; `purge --keep-downloads` keeps the tarballs. | `store-loop-system` CI job |

**HITL-only for this feature:** the system job forces `L4T_STORE_BACKEND=loop-image` on an ext4 runner. It proves the loop lifecycle, not ntfs-3g behaviour — sparse-file allocation and prepare throughput through ext4 → loop → FUSE → NTFS can only be observed on a real NTFS checkout.

## Test levels for the host NFS export (#101)

`script/lib/nfs_export.sh` — exporting the prepared L4T tree from the host `nfs-kernel-server` so the host's `rpc.mountd` stops answering the board with an empty export table.

| Level | Where | What it proves | Runs in |
|---|---|---|---|
| **Unit** | `test/smoke/nfs_export_lib.bats` | The three paths; per path `exportfs -u` → `-o rw,nohide,insecure,no_subtree_check,async,no_root_squash "[fc00:1:1::/48]:<path>"`, then one `exportfs -f`; a failed unexport does not stop the export; re-run idempotent; no `exportfs` on PATH → message + exit 0, nothing touched; missing `rootfs` / `images` → `emit_error host-config`, exit 1, nothing exported; `tools/kernel_flash/tmp` created when missing; IPv4 client gets no brackets; `nfs_export_off` unexports the three + flushes and ignores "not exported"; `nfs_host_mountd_running` via `pgrep -x`; status reads `/var/lib/nfs/etab` (no sudo) and is ok / warn per host mountd × exports; the single `.prepared.yaml` maps to the `/srv` path (0 → 1, 2 → 2). | `devel-test` stage |
| **Integration** | `test/smoke/host_setup.bats`, `host_teardown.bats`, `jetson_cli.bats` | `host_setup.sh` exports after the `/srv` bridge with the host paths, and skips with a message when nothing is prepared; `host_teardown.sh` unexports *before* the bridge umount; `./jetson flash` re-exports after `sudo -v` and before `nm_flash_guard`, and stops before the guard when the export fails; `./jetson status` ⚠ on host `rpc.mountd` + missing exports, quiet otherwise, never sudo. `exportfs` / `pgrep` / `sudo` stubbed on PATH. | `devel-test` stage |
| **System / Acceptance** | HITL | A host that runs `nfs-kernel-server` flashes end to end; `grep -E '^rc\|^net' /proc/net/rpc/nfsd` moves as soon as the export is in place; a re-prepare does not produce *Stale file handle*. Verified once on AGX Orin 64 GB, 2026-09-16 (manual `exportfs`, before this code). | hardware only |

## Verification status (per preset)

Be honest about what has actually been flashed versus what is only known to build and validate.

**What CI proves (and only this):** image build for every stage, `shellcheck` + `hadolint` lint, the `bats` smoke suite, and `sdkmanager --ver`. **CI does NOT run a real flash** — no Jetson hardware is attached in CI, so no end-to-end flash, NFS serve, or eMMC write is exercised there. See the HITL-ONLY section below for the steps only hardware-in-the-loop testing can cover.

Per-preset status:

| Preset | Status |
|---|---|
| `agx-orin-emmc.yaml` | verified on hardware 2026-06, JetPack 6.2.2 |
| `agx-orin-nvme.yaml` | config-validated only |
| `agx-orin-usb.yaml` | config-validated only |
| `orin-nx-nvme.yaml` | config-validated only |
| `orin-nano-nvme.yaml` | config-validated only |
| `orin-nano-sd.yaml` | config-validated only |

"config-validated only" means the preset parses, resolves its aliases, and builds flash images, but the full `flash` stage to that board + storage has not yet been confirmed on real hardware. The mechanism is identical across presets, so config-validated presets are expected to work; they just have not been signed off end to end.

## What CI actually proves

CI is build-and-lint plus a tiny smoke suite. It runs on GitHub-hosted x86_64 runners with **no Jetson attached**, so nothing below the line "real flash" is exercised:

- Image build for every Dockerfile stage.
- `shellcheck` + `hadolint` lint.
- The `bats` smoke suite (this file).
- The `store-loop-system` job: a real loop-mounted ext4 store on the runner (see the test-levels table above).
- `sdkmanager --ver` (the `cli-test` / `gui-test` stages).

CI does **NOT** flash a board, serve NFS to a device, or write eMMC / NVMe / USB / SD. Treat green CI as "it builds and the scripts are well-formed", not "it flashes".

## HITL-ONLY paths (CI cannot verify these)

The following steps require **hardware in the loop** (a Jetson in APX recovery on a real host). None of them run in CI; each can only be checked by a human flashing a board:

- **eMMC discard patch** — the on-device flash script's skip-eMMC-discard behaviour. Only observable against real eMMC silicon.
- **Device-served NFS flash** — the `flash` stage serving the payload to the Jetson's initrd over a local NFS export across the `tegrarcm_v2` USB link. Needs the host `nfsd` module and a booted-to-initrd device.
- **SDK Manager flash** — a real `sdkmanager --cli` / GUI flash, including its device-mode forwarding (`iptables` + `dig`). CI only smokes `sdkmanager --ver`.
- **The `/srv/jetson_l4t` bridge** — `host_setup.sh` bridging the flash export path into the host mount namespace so the host kernel `nfsd` can serve the container-only bind mount. Only meaningful during an actual device-served flash.

Because these are HITL-only, a passing CI run says nothing about them; sign-off for each comes from the per-preset verification table above.
