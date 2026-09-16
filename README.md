# Jetson Orin Factory-Flash Container

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](./LICENSE)

Flash a **Jetson Orin** (AGX Orin, Orin NX, Orin Nano) from any x86_64 Linux box with **three commands**. NVIDIA's `l4t_initrd_flash.sh` runs inside Docker, so the host needs Docker and nothing else — no SDK Manager, no NVIDIA login. Built on [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base).

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

| JetPack | L4T | Status |
|---|---|---|
| **6.2.2** | R36.5.0 (`r36_release_v5.0`) | the only release wired up today — [add another](#configure-jetsonyaml) |

---

- [Quick start](#quick-start)
- [Entering recovery (REC) mode](#entering-recovery-rec-mode)
- [After the flash](#after-the-flash)
- [Prerequisites](#prerequisites)
- [Configure `jetson.yaml`](#configure-jetsonyaml)
- [Data, cleanup, removing the repo](#data-cleanup-removing-the-repo)
- [Troubleshooting](#troubleshooting)
- [Going deeper](#going-deeper)

## Quick start

```bash
git clone https://github.com/ycpss91255-docker/jetson_sdk_manager.git   # git clone, NOT "Download ZIP" (the .base/ subtree is missing from the zip)
cd jetson_sdk_manager

./jetson status      # what is ready, what is not — fix any ✘ it shows
./jetson prepare     # host setup (asks for sudo once) + download BSP + build flash images. ~30 min, no board needed
#   → put the Jetson into recovery: see the next section
./jetson flash       # write the images over USB. ~10 min
```

`./jetson all` does the three in a row and waits for you to put the board into recovery in between. Everything `./jetson` runs is an ordinary script or `make` target — see [Going deeper](#going-deeper).

What it takes: an x86_64 Linux host with Docker (usable without `sudo`), one USB-C cable, ~20 GB free, and roughly 40 minutes the first time (later runs skip the download and the finished steps). A checkout on NTFS / exFAT is fine — `prepare` handles it ([how](#prerequisites)).

## Entering recovery (REC) mode

The Jetson's Boot ROM only accepts a flash while the board is in **Force Recovery** ("REC" / "APX" / "RCM" — same thing). You enter it with the buttons on the devkit; the host then sees a USB device `0955:7023`-ish instead of the booted OS.

**AGX Orin Developer Kit** — the three buttons (Power, Force Recovery, Reset) sit under the front edge, and the USB-C port that supports **device / recovery mode** is the one right next to them (the other USB-C, further along, is DisplayPort-capable and does *not* flash). Schematic — for the real photo and connector designators see NVIDIA's user guide linked below:

```
  front edge of the AGX Orin devkit (schematic, not to scale)

   ┌──────────┐    ┌─────┐  ┌─────┐  ┌─────┐
   │  USB-C   │    │ PWR │  │ REC │  │ RST │
   └──────────┘    └─────┘  └─────┘  └─────┘
     ▲ flash /        power   force    reset
       device-mode            recovery
       port
```

1. Disconnect the power supply.
2. Connect the USB-C cable from **the device-mode USB-C port (next to the buttons)** to the host. Direct connection — no hub. If `./jetson status` never sees the board, try the other USB-C port before anything else.
3. **Hold REC** (the middle button).
4. Reconnect power (or press PWR while still holding REC).
5. Release REC after about 2 seconds.

Alternative when the board is already powered: hold **REC**, tap **RST**, release REC after ~2 s.

**Orin NX / Orin Nano Developer Kit** — the carrier has no buttons. Short the **`FC REC`** and **`GND`** pins on the 12-pin button header (J14) with a jumper wire, then apply power (or tap `RST`), then remove the jumper. Pin names are printed on the carrier; the official user guide has the photo.

Check from the host:

```bash
./jetson status          # last line: "Jetson in recovery: … 0955:7023 NVIDIA Corp. APX"
./jetson wait-rec        # or: print these steps and wait until the board shows up
```

| USB ID the host sees | Meaning |
|---|---|
| `0955:7023` (AGX Orin) · `7223` · `7423` · `7523` · `7e19` — `NVIDIA Corp. APX` | in recovery — ready to flash (the PID encodes the module SKU; `script/lib/usb.sh` is the list `flash` accepts) |
| `0955:7020 … L4T (Linux for Tegra) running on Tegra` | booted into the OS — redo the sequence |
| nothing | not detected — other cable / port / no hub; check the cable is on the port next to the buttons |

Recovery runs over USB 2.0; that is normal. The board stays in recovery until power-cycled, so entering it early and flashing later is fine. For the official photos and the full button reference see NVIDIA's [Jetson AGX Orin Developer Kit User Guide](https://developer.nvidia.com/embedded/learn/jetson-agx-orin-devkit-user-guide/index.html) and the [Jetson Linux Quick Start](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/IN/QuickStart.html) (section "To Flash the Jetson Developer Kit Operating Software" — "force recovery mode").

## After the flash

The Jetson reboots into the freshly flashed OS. Over the **same USB-C cable** it is reachable at a fixed address (NVIDIA's USB device-mode, nothing to configure):

```bash
ssh jetson@192.168.55.1          # user / password from jetson.yaml (default jetson / jetson)
passwd                           # change the default password NOW — it is well known
sudo apt update && sudo apt install -y nvidia-jetpack     # CUDA, cuDNN, TensorRT, VPI, … (what SDK Manager would push)
```

The host gets a `192.168.55.x` address on the USB network interface automatically (`./jetson flash` re-enables NetworkManager on it the moment the board boots). Ethernet / Wi-Fi are DHCP by default; a static profile can be baked in via the optional `network:` block in `jetson.yaml`.

Done with the host? `./jetson teardown` undoes the kernel / mount changes in this boot (a reboot does the same).

## Prerequisites

- **x86_64 Linux** host (not WSL, not a VM on macOS for the flash step), **Docker ≥ 20.10** usable without `sudo` (`docker run --rm hello-world`; else `sudo usermod -aG docker "$USER"` and re-login), `make`, `lsusb`.
- **~20 GB free** for the BSP, rootfs and generated images; ~4 GB of that is the one-time download.
- **`./data/jetson_l4t/` must be ext4 / xfs / btrfs** — `apply_binaries.sh` writes setuid + root-owned files that NTFS / exFAT / FAT silently drop, producing a Jetson whose `sudo` is broken. You do not have to move the repo: on such a checkout `./jetson prepare` (via `host_setup.sh`) creates a sparse ext4 image **inside the repo** (`data/jetson_l4t.img`, `L4T_STORE_SIZE=40G` logical) and loop-mounts it over `data/jetson_l4t/`. Needs `e2fsprogs` + `util-linux` (`mkfs.ext4`, `losetup`). Prefer a directory on another ext4 disk? `L4T_STORE_DIR=/path/on/ext4 ./jetson prepare`. The loop path is slower than a native ext4 checkout, mostly during rootfs extraction.
- **Per boot**: `./jetson prepare` re-runs `host_setup.sh` (QEMU binfmt, `nfsd`, USB autosuspend / buffer, the `/srv/jetson_l4t` bridge, the data store mount). Nothing persists across reboots; `./jetson status` tells you when it is needed again.
- **NetworkManager hosts** (most desktops/laptops): NM tears the USB link down mid-flash unless guarded. `./jetson flash` runs `nm_flash_guard.sh auto` for you; only skip it if you know the host does not run NM.

## Configure `jetson.yaml`

`jetson.yaml` is a symlink to a preset under `config/jetson/`. The default (`agx-orin-emmc.yaml`) flashes an AGX Orin devkit — 32 GB or 64 GB, same target — to its eMMC. Pick the one matching your board + storage:

| Preset | Board | Storage |
|---|---|---|
| `agx-orin-emmc.yaml` | AGX Orin devkit | eMMC (`mmcblk0p1`) |
| `agx-orin-nvme.yaml` | AGX Orin devkit | NVMe (`nvme0n1p1`) |
| `agx-orin-usb.yaml` | AGX Orin devkit | USB SSD (`sda1`) |
| `orin-nx-nvme.yaml` | Orin NX devkit-super | NVMe |
| `orin-nano-nvme.yaml` | Orin Nano devkit-super | NVMe |
| `orin-nano-sd.yaml` | Orin Nano devkit-super | microSD via USB reader |

Switch presets by re-symlinking:

```bash
ln -sf config/jetson/orin-nx-nvme.yaml jetson.yaml
```

Each preset sets:

- `jetpack.version` — resolved to L4T release + BSP / rootfs URLs via `config/jetson/_l4t_mapping.yaml`.
- `hardware.board` — alias → NVIDIA `--target` name.
- `storage.device` — alias → storage mode (`internal` for eMMC, `external` for NVMe / USB / SD) + default kernel device path the Jetson recovery initrd is told to write.
- `user.{username,password,hostname,autologin}` — pre-creates the default user via `l4t_create_default_user.sh`, skipping OEM-config on first boot. The presets ship the default `jetson` / `jetson` credentials; **change the password after your first login** (`passwd` on the device), and set a different one here before flashing if the board will ever be network-reachable.
- `network` (optional) — DHCP by default; set `method: static` to install a `NetworkManager` system-connection profile.

**Multi-slot USB readers / non-default device enumeration.** When a USB SSD or microSD reader exposes the storage on a non-default LUN (typically the empty slot shows up as `sda` and the card lands on `sdb`), add `storage.device_path` to override the alias-resolved kernel device:

```yaml
storage:
  device: usb
  device_path: sdb1      # overrides the usb alias's sda1 default
```

To find the right value, plug the storage into the host first and run `lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN`; the Jetson recovery initrd usually mirrors host enumeration. If the first flash still aborts on `Error opening /dev/sd*: No medium found`, try the next letter (`sdb1` → `sdc1`) — see [Troubleshooting](#error-error-opening-devsda-no-medium-found-microsd-via-usb-reader). Setting `device_path` together with `storage.device: emmc` (internal mode) is rejected at validation time.

See `config/jetson/_example.yaml` for the full schema with comments.

**To add a JetPack release** the presets do not yet support: edit `config/jetson/_l4t_mapping.yaml` to add a new entry under `jetpack_to_l4t` (with the `l4t_release` and `bsp_url` / `rootfs_url` from [Jetson Linux Archive](https://developer.nvidia.com/embedded/jetson-linux-archive)), then rebuild the prepare / flash images.

## Data, cleanup, removing the repo

Everything lives under the checkout, gitignored: `data/downloads/` (tarballs), `data/jetson_l4t/` (BSP + rootfs + images — the ext4 image `data/jetson_l4t.img` on NTFS checkouts), `data/nvsdkm/` + `data/nvidia_sdk/` (SDK Manager only), `log/`. The container sees `data/jetson_l4t/` as `/srv/jetson_l4t` and `jetson.yaml` as `/etc/jetson.yaml` (read-only).

Each phase records progress in `.prepared.yaml`; re-running `./jetson prepare` skips what is done. Changing the JetPack / board after a prepare is detected as a mismatch and asks you to `./script/clean.sh l4t` first.

### Clean targets

`script/clean.sh` operates on `./data/jetson_l4t/` via a transient `alpine:3` container, so no host-side tooling is needed.

| Command | Effect |
|---|---|
| `./script/clean.sh build` | Remove generated flash images (`tools/kernel_flash/images/`) only. |
| `./script/clean.sh rootfs` | Remove `rootfs/`, keep BSP + downloaded tarballs. |
| `./script/clean.sh l4t` | Remove the entire `Linux_for_Tegra/` tree (BSP + rootfs + images). Keep tarballs. |
| `./script/clean.sh all` | l4t + remove `data/downloads/` tarballs. |
| `./script/clean.sh purge` | `all` + `host_teardown.sh` + delete the L4T data store itself (the in-repo `data/jetson_l4t.img`, or the `L4T_STORE_DIR` directory) and its `data/.l4t_store` marker. The strongest clean — see [Removing the repo](#removing-the-repo). `--keep-downloads` spares the tarballs so the next prepare skips the ~3 GB download. |

Run `./script/clean.sh l4t` to recover from a JetPack version mismatch reported by `prepare.sh`. `purge` validates the marker before touching anything: a marker from another checkout, a malformed one, or a store path it does not recognise aborts with a diagnostic and deletes nothing.

### Removing the repo

Everything this repo produces lives under the checkout (`data/`, `log/`, the derived `.env` / `compose.yaml`) — with two boot-scoped exceptions on the host: the mounts `host_setup.sh` creates (`./data/jetson_l4t` on an NTFS checkout, and the `/srv/jetson_l4t` NFS bridge) and the kernel USB / nfsd settings. Those vanish on reboot, or right now with `host_teardown.sh`. So the contract is:

```bash
./jetson purge               # unmount + delete the store, tarballs, marker (add --keep-downloads to keep tarballs)
cd .. && rm -rf jetson_sdk_manager
```

After `purge`, `rm -rf` of the checkout leaves **no residue**: no mount, no loop device, no `/srv/jetson_l4t`, nothing in `/var/lib` or your home directory. This is verified in CI by the `store-loop-system` job (real loop mount on the runner, then `rm -rf` of a throw-away clone).

Do **not** `rm -rf` the checkout while `./data/jetson_l4t` is still mounted: `rm` recurses *through* the mount (deleting the store's contents, which is what you wanted) and then fails on the mountpoint itself, leaving a loop device attached to an unlinked image until you `umount`. Run `purge` (or at least `host_teardown.sh`) first. Also note `/srv/jetson_l4t` is one fixed path, so two checkouts cannot be set up on the same host at the same time.

Two deliberate exceptions to "everything under the checkout": Docker images (`make build` output — `docker rmi` if you want them gone), and a store you explicitly placed elsewhere with `L4T_STORE_DIR`. For the latter, `purge` empties it through the same alpine pass and then only `rmdir`s the empty directory — it never `rm -rf`s a path read from the marker — so if anything else was put in that directory, purge stops and tells you.

## Troubleshooting

`./jetson status` diagnoses the common ones. Every known failure, with its exact error text and fix, is in **[doc/TROUBLESHOOTING.md](doc/TROUBLESHOOTING.md)**:

- `prepare.sh` aborts: *L4T_ROOT … is on ntfs/exfat/fuseblk* · *volume mismatch* · `chroot: … Exec format error`
- *Could not detect a board* / Jetson not in recovery
- `RPC: Program not registered` / *NFS server is not running* / `Error 114` (at the start of flash)
- Flash stalls mid-transfer / "Flashing – 99 %" / `mount.nfs: No such file or directory` (NetworkManager)
- `ERROR: might be timeout in USB write` / `Return value 3`
- `Error opening /dev/sda: No medium found` (microSD via USB reader) · flash hangs on the APP partition
- SDK Manager: *Device mode forwarding host setup failed* · GUI component install hangs

## Going deeper

- **[doc/ARCHITECTURE.md](doc/ARCHITECTURE.md)** — what each `./jetson` command runs under the hood, `host_setup.sh` step by step, the Docker stages, the two flashing paths (factory flash vs. SDK Manager `cli` / `gui`), persistent data, the build graph, directory layout.
- **[doc/Flash_Workflow.md](doc/Flash_Workflow.md)** — the `prepare` / `flash` phases in detail.
- **[doc/test/TEST.md](doc/test/TEST.md)** — what CI proves (build, lint, bats, a real loop-mount lane) and what only hardware can (per-preset verification status: `agx-orin-emmc` verified on hardware 2026-06; the other presets are config-validated only).
- **[doc/adr/](doc/adr/)** — architecture decisions; **[doc/changelog/CHANGELOG.md](doc/changelog/CHANGELOG.md)**.
