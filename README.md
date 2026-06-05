# Jetson Orin Factory-Flash Container

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](./LICENSE)

Containerized NVIDIA Jetson Linux (L4T) factory-flash workflow for Jetson Orin devices (AGX Orin, Orin NX, Orin Nano). Wraps `l4t_initrd_flash.sh --no-flash` / `--flash-only` from the official BSP archive into two reproducible Docker stages. Built on [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base).

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

---

## Table of Contents

- [TL;DR](#tldr)
- [Why factory flash, not SDK Manager](#why-factory-flash-not-sdk-manager)
- [Prerequisites](#prerequisites)
- [Configure `jetson.yaml`](#configure-jetsonyaml)
- [Quick Start](#quick-start)
- [Stages](#stages)
- [Clean Targets](#clean-targets)
- [Inspector (SDK Manager GUI)](#inspector-sdk-manager-gui)
- [Persistent Data](#persistent-data)
- [Architecture](#architecture)
- [Smoke Tests](#smoke-tests)
- [Directory Structure](#directory-structure)
- [Troubleshooting](#troubleshooting)

---

## TL;DR

```bash
./script/host_setup.sh                                # one-time per boot: qemu + nfsd + USB tweaks (run on host)
./script/init_data_dirs.sh                            # first run only: pre-create data/ mounts as you, not root
ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml   # pick a preset

make run -- -t prepare    # Phase 1: download BSP + build flash images (~30 min)
# Put Jetson in APX recovery (hold REC + tap RESET)
./script/nm_flash_guard.sh auto   # stop NetworkManager tearing down the USB transfer; auto-restores when the board boots
make run -- -t flash      # Phase 2: write images to Jetson (~10 min)

# ...or, with the Jetson already in APX recovery, do both in one command:
make run -- -t prepare && ./script/nm_flash_guard.sh auto && make run -- -t flash
```

> `./script/host_setup.sh` bundles the per-boot host prerequisites (see [Prerequisites](#prerequisites)); `make run` auto-builds a missing stage image on first invocation. For an explained walkthrough — `make build` per stage, post-flash `nvidia-jetpack` install, headless access, and resume behaviour — see [Quick Start](#quick-start).

## Why factory flash, not SDK Manager

NVIDIA SDK Manager's GUI / `--cli` workflow flashes a Jetson by running an NFS server on the host and exporting the rootfs to the device over a USB device-mode link, while bridging it through the host's network stack via `iptables`. Inside Docker (even with `--privileged --network host`) this combination is broken: NFS server cannot bind reliably, `iptables` rules from inside the container do not always reach the host's nftables, and `usb-gadget` device-mode forwarding fails. The symptom is the well-known [Flashing - 99% stall](https://forums.developer.nvidia.com/t/docker-sdk-manager-flash-nx-struck-at-99/365066) that affects NVIDIA's own Docker image as well.

This repo bypasses that path entirely. The **prepare** stage uses the BSP's own `l4t_initrd_flash.sh --no-flash` to build flash images host-side (no Jetson, no NFS, no `iptables`); the **flash** stage then writes them with `--flash-only`: the Jetson boots a minimal initrd over the `tegrarcm_v2` USB link and pulls the images from a local NFS export on that same link. That export still needs the host's `nfsd` kernel module loaded (see [Prerequisites](#prerequisites)), but — unlike SDK Manager — there is no `iptables` manipulation and no `usb-gadget` device-mode forwarding, so it works reliably in a privileged container.

SDK Manager is still shipped — in the **`inspector`** stage — as a catalog browser for looking up which `.deb` packages a given JetPack release contains. Its Install button stays broken inside Docker; the entrypoint prints a banner saying so.

## Prerequisites

- **Host OS**: x86_64 Linux.
- **Docker Engine** >= v20.10.6.
- **Host filesystem of the repo: ext4 / xfs / btrfs.** `apply_binaries.sh` produces setuid binaries (`sudo`) and root-owned files inside the rootfs tree. NTFS / exFAT / `fuseblk` / FAT silently strip setuid and ownership during extraction, which yields a flashed Jetson whose `sudo` refuses to start. `prepare.sh` aborts with an action message if the path is on one of these filesystems; move the repo (or bind-mount an ext4 directory over `./data/jetson_l4t/`) before re-running.
- **Per-boot host setup — `./script/host_setup.sh`.** Run it on the host before connecting the Jetson. One command registers **QEMU binfmt** (run the BSP's ARM64 tools during `prepare`), loads the **`nfsd`** module (the `flash` stage serves the payload to the Jetson's initrd over a local NFS export — no `iptables` / `usb-gadget` forwarding), disables **USB autosuspend** and raises the **`usbfs` buffer** to 2048 MB (the last two stop `tegrarcm_v2` / NFS bulk writes stalling mid-flash). Everything resets on reboot, so re-run it each boot. Two things it does **not** do for you:
  - **Persist `nfsd`** to skip it next boot: `echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf`.
  - **Per-device autosuspend override**, if one port still parks the device (find it via `lsusb -t` once the Jetson is in APX): `echo on | sudo tee /sys/bus/usb/devices/<bus>-<port>/power/control`.

  Symptoms when skipped: no QEMU → `chroot: ... Exec format error` during `prepare`; no `nfsd` → `RPC: Program not registered` / `Return value 114` during `flash`. `prepare` needs only the QEMU step.
- **Jetson in APX recovery** (for the `flash` stage only; `prepare` needs no Jetson connected).

## Configure `jetson.yaml`

The top-level `jetson.yaml` is a symlink to one of the presets under `config/jetson/`. Pick one matching your board + storage target:

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
- `user.{username,password,hostname,autologin}` — pre-creates the default user via `l4t_create_default_user.sh`, skipping OEM-config on first boot.
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

## Quick Start

> **Before `make run`:** run `./script/host_setup.sh` once per boot (QEMU binfmt, `nfsd`, USB tweaks — see [Prerequisites](#prerequisites)), and `./script/init_data_dirs.sh` on the first run (otherwise the Docker daemon `mkdir`s the `data/` mounts as root, blocking the container's non-root user).

```bash
./script/host_setup.sh      # once per boot: QEMU binfmt + nfsd + USB tweaks (run on host)
./script/init_data_dirs.sh  # first run only
ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml

# Phase 1 — host-side image build (no Jetson connected)
make build -- -t prepare
make run -- -t prepare

# Phase 2 — write to Jetson
# Put Jetson into APX recovery: power off, hold REC, reconnect power, release.
make build -- -t probe   # one stage per build — last -t wins, so build them separately
make build -- -t flash
make run -- -t probe     # confirm Jetson visible in APX (exits 0 on success)
./script/nm_flash_guard.sh auto   # see "NetworkManager" note below
make run -- -t flash
```

On a host running NetworkManager (most laptops/desktops), the flash can stall partway with a misleading `NFS server` / `Error 114` failure: NM tries to DHCP the Jetson's USB gadget interface, times out, and removes the address mid-transfer. `./script/nm_flash_guard.sh auto` marks that interface unmanaged for the flash, then **re-enables NM automatically the moment the board re-enumerates as the booted device (`0955:7020`)** — so the host immediately picks up `192.168.55.x` and you can SSH in, with no manual `enable` step. A timeout (default 1800s, override with the first arg) restores NM even if the flash aborts. See [`nm_flash_guard.sh`](script/nm_flash_guard.sh) for `disable` / `enable` / `around` / `status` subcommands.

After the Jetson boots into the freshly flashed OS, install the rest of JetPack from NVIDIA's OTA apt repository:

```bash
sudo apt update
sudo apt install -y nvidia-jetpack
```

This installs CUDA, cuDNN, TensorRT, VPI, multimedia APIs, container runtime, etc. — the same component set SDK Manager would push, just pulled directly by the Jetson.

### Headless first connection (USB, no network setup)

The flashed L4T rootfs ships NVIDIA's USB device-mode service, so the Jetson is reachable at a fixed **`192.168.55.1`** over the same USB-C cable used to flash — no `jetson.yaml` `network:` config required:

```bash
ssh <username>@192.168.55.1     # username / password from jetson.yaml's user.* block
```

The host auto-configures a `192.168.55.x` address on the USB network interface (check with `ip a`). This link is independent of the optional [`network:`](#configure-jetsonyaml) block — which configures the Jetson's Ethernet / Wi-Fi via NetworkManager — and both coexist. The `192.168.55.1` address is baked into L4T and cannot be changed from this repo.

### Resume after interruption

Each phase records progress in `data/jetson_l4t/.../.prepared.yaml`. Re-running `make run -- -t prepare` skips completed steps (BSP download, rootfs extraction, `apply_binaries.sh`, user creation, image generation). A JetPack / board change is detected as a mismatch and aborts with an action message pointing at `./script/clean.sh l4t`.

## Stages

| Stage | Purpose | Jetson required |
|---|---|---|
| `devel` | Flash tooling (`l4t_initrd_flash.sh` dependencies). Default `make build` target. | No |
| `devel-test` | Lint (`shellcheck` + `hadolint`) + bats smoke tests. CI-only. | No |
| `prepare` | Phase 1 — download BSP + sample rootfs, `apply_binaries.sh`, `l4t_create_default_user.sh`, `l4t_initrd_flash --no-flash`. | No |
| `flash` | Phase 2 — `l4t_initrd_flash --flash-only`. | **Yes**, in APX recovery |
| `probe` | Diagnostic. Scans USB for NVIDIA vendor `0955`, annotates each device with recovery vs not, exits non-zero unless at least one Jetson is in APX. Run before flash to confirm the link without committing to a full flash. | Recommended |
| `sdkm-base` | Shared SDK Manager layer (`sdkmanager` + `iptables` + `dnsutils`) for `cli` / `inspector`. Not run directly. Keeps `devel` slim. | No |
| `cli` | SDK Manager **headless CLI** — a best-effort alternative flash path (`sdkmanager --cli`). The factory `prepare`/`flash` stages remain the supported default. | For flashing |
| `cli-test` | `sdkmanager --ver` sanity check. CI-only. | No |
| `inspector` | SDK Manager GUI for browsing the JetPack component catalog. Flash button is best-effort — see [Inspector](#inspector-sdk-manager-gui). | No |
| `inspector-test` | `sdkmanager --ver` sanity check. CI-only. | No |

## Clean Targets

`script/clean.sh` operates on `./data/jetson_l4t/` via a transient `alpine:3` container, so no host-side tooling is needed.

| Command | Effect |
|---|---|
| `./script/clean.sh build` | Remove generated flash images (`tools/kernel_flash/images/`) only. |
| `./script/clean.sh rootfs` | Remove `rootfs/`, keep BSP + downloaded tarballs. |
| `./script/clean.sh l4t` | Remove the entire `Linux_for_Tegra/` tree (BSP + rootfs + images). Keep tarballs. |
| `./script/clean.sh all` | l4t + remove `data/downloads/` tarballs. |

Run `./script/clean.sh l4t` to recover from a JetPack version mismatch reported by `prepare.sh`.

## Inspector (SDK Manager GUI)

The `inspector` stage ships NVIDIA SDK Manager as a **catalog browser** — not a flash tool. Use it to look up which `.deb` packages a given JetPack release contains, or to download individual `.deb` files outside of `apt install nvidia-jetpack`.

```bash
make build -- -t inspector
make run -- -t inspector
```

The entrypoint prints a banner explaining why the Install button is broken inside Docker, then (in interactive mode) waits for Enter before launching the GUI. Any extra positional args after `-t inspector` are forwarded verbatim to `sdkmanager-gui` (after `--no-sandbox`). The warning banner and the Enter prompt are always shown and cannot be disabled.

GUI mode requires an X11 session on the host; the base template auto-detects `$DISPLAY` and forwards the X11 socket + `XAUTHORITY`.

## Persistent Data

Each path under `./data/` is bind-mounted into the container (gitignored).

| Host path | Container path | Purpose |
|---|---|---|
| `./data/jetson_l4t/` | `/srv/jetson_l4t` | BSP + rootfs + generated flash images (factory-flash workflow). **Must be ext4 / xfs / btrfs.** |
| `./data/downloads/` | `${HOME}/Downloads/nvidia/sdkm_downloads` | Cached tarballs (BSP + sample rootfs), shared with SDK Manager. |
| `./data/nvsdkm/` | `${HOME}/.nvsdkm` | SDK Manager login session cache. Inspector stage only. |
| `./data/nvidia_sdk/` | `${HOME}/nvidia/nvidia_sdk` | SDK Manager-managed SDK install folder. Inspector stage only. |
| `./jetson.yaml` | `/etc/jetson.yaml` (read-only) | User config, read by `prepare.sh` / `flash.sh` / `inspector-entrypoint.sh`. |

## Architecture

```mermaid
graph TD
    EXT1["test-tools image\nbats + shellcheck + hadolint"]
    EXT2["ubuntu:${BASE_IMAGE}\n(22.04 / 24.04)"]
    EXT3["NVIDIA Jetson Linux Archive\nBSP + sample rootfs tarballs"]
    EXT4["CUDA apt repo\ncuda-keyring + sdkmanager"]

    EXT2 --> sys["sys\nuser/group, locale, timezone"]
    sys --> devel-base["devel-base\ndev tools (git, vim, tmux, curl, wget)"]
    devel-base --> devel["devel\nflash tooling + yq binary"]

    devel --> prepare["prepare\nCMD prepare.sh\n(host-side image build)"]
    EXT3 --> prepare
    devel --> flash["flash\nCMD flash.sh\n(USB write to Jetson)"]
    devel --> probe["probe\nCMD probe.sh\n(lsusb 0955 sanity check)"]
    devel --> sdkm-base["sdkm-base\n+ SDK Manager + iptables + dnsutils"]
    EXT4 --> sdkm-base
    sdkm-base --> cli["cli\nCMD sdkmanager --cli\n(best-effort flash path)"]
    sdkm-base --> inspector["inspector\n+ X11 libs\nCMD inspector-entrypoint.sh"]

    EXT1 --> devel-test["devel-test (ephemeral)\nshellcheck + hadolint + bats"]
    devel --> devel-test
    inspector --> inspector-test["inspector-test (ephemeral)\nsdkmanager --ver"]
```

## Smoke Tests

See [TEST.md](doc/test/TEST.md).

```bash
make build test
```

The `devel-test` stage runs the bats suite against the `devel` image; the two `sdkmanager` assertions are skipped there (they only run when bats is re-executed inside the `inspector` image).

## Directory Structure

```text
jetson_sdk_manager/
├── jetson.yaml -> config/jetson/agx-orin-emmc.yaml   # symlink; switch presets here
├── compose.yaml                 # Docker Compose (derived, gitignored)
├── Dockerfile                   # sys → devel-base → devel → {prepare, flash, inspector}
├── Makefile -> .base/script/docker/Makefile
├── .base/                       # Shared template (git subtree)
├── data/                        # Persistent state (gitignored)
│   ├── jetson_l4t/              #   BSP + rootfs + flash images
│   ├── downloads/               #   BSP / rootfs tarballs
│   ├── nvsdkm/                  #   SDK Manager login session (inspector)
│   └── nvidia_sdk/              #   SDK Manager install folder (inspector)
├── config/
│   ├── docker/setup.conf        # Runtime config — source of truth
│   ├── jetson/                  # Flash presets + schema
│   │   ├── _example.yaml        #   Canonical schema with comments
│   │   ├── _l4t_mapping.yaml    #   JetPack → L4T release / URLs (build-time)
│   │   └── *.yaml               #   Per-board / per-storage presets
│   └── packages/                # X11 lib lists for inspector (per Ubuntu codename)
├── doc/
│   ├── adr/                     # Architecture Decision Records
│   ├── changelog/CHANGELOG.md
│   ├── test/TEST.md
│   ├── Flash_Workflow.md        # Deep-dive into the prepare/flash phases
│   ├── README.zh-TW.md
│   ├── README.zh-CN.md
│   └── README.ja.md
├── script/
│   ├── prepare.sh               # Phase 1 entrypoint
│   ├── flash.sh                 # Phase 2 entrypoint
│   ├── clean.sh                 # Volume cleanup targets
│   ├── inspector-entrypoint.sh  # SDK Manager GUI launcher + warning banner
│   ├── lib/                     # yaml / download / volume / errors helpers
│   ├── host_setup.sh            # One-shot per-boot host prereqs (qemu/nfsd/USB)
│   ├── init_data_dirs.sh        # First-time data/ mkdir as non-root
│   ├── entrypoint.sh            # Container entrypoint (logging tee)
│   ├── build.sh -> ../.base/script/docker/wrapper/build.sh
│   ├── run.sh   -> ../.base/script/docker/wrapper/run.sh
│   ├── exec.sh  -> ../.base/script/docker/wrapper/exec.sh
│   ├── stop.sh  -> ../.base/script/docker/wrapper/stop.sh
│   ├── setup.sh -> ../.base/script/docker/wrapper/setup.sh
│   ├── setup_tui.sh -> ../.base/script/docker/wrapper/setup_tui.sh
│   └── prune.sh -> ../.base/script/docker/wrapper/prune.sh
├── test/smoke/orin_install_env.bats
├── .github/workflows/main.yaml
└── .gitignore
```

## Troubleshooting

### `prepare.sh` aborts: "L4T_ROOT ... is on ntfs/exfat/fuseblk"

`apply_binaries.sh` creates setuid binaries (`sudo`) and root-owned files. NTFS / exFAT / `fuseblk` / FAT silently drop both, which produces a flashed Jetson whose `sudo` refuses to start. Either move the repo to an ext4 / xfs / btrfs partition, or bind-mount an ext4 directory over `./data/jetson_l4t/`:

```bash
sudo mkdir -p /var/lib/jetson_l4t
sudo mount --bind /var/lib/jetson_l4t ./data/jetson_l4t
```

The bind-mount target does not have to live on the system disk — any directory on an ext4 / xfs / btrfs partition works, including a path on a secondary SSD or an already-mounted data drive. Pick the one with enough free space (~15 GB for one full prepare):

```bash
sudo mkdir -p /media/<ext4-mount>/jetson_l4t
sudo mount --bind /media/<ext4-mount>/jetson_l4t ./data/jetson_l4t
```

Either form of the bind mount is non-persistent; re-apply it after a reboot before running `make run -- -t prepare`.

For diagnostic purposes only, `JETSON_ALLOW_NON_UNIX_FS=1` downgrades the abort to a warning:

```bash
JETSON_ALLOW_NON_UNIX_FS=1 make run -- -t prepare
```

This **cannot produce a working flash** on a non-unix filesystem. NVIDIA's `apply_binaries.sh` has its own root-ownership check (`find rootfs/etc/passwd -user root -group root`) that aborts step 7/10 once the sample rootfs has extracted under the wrong owner. The escape hatch only exists so a maintainer can run prepare far enough to observe the failure mode empirically; it is not a workaround for the underlying filesystem constraint.

### `prepare.sh` aborts: volume mismatch

The `.prepared.yaml` marker says the volume was prepared for a different JetPack / board than `jetson.yaml` now selects. Wipe and re-run:

```bash
./script/clean.sh l4t
make run -- -t prepare
```

### `chroot: failed to run command 'dpkg': Exec format error`

Host kernel cannot execute ARM64 binaries. Register the QEMU binfmt interpreter:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Run once per host boot.

### `Could not detect a board` / Jetson not in recovery

`flash.sh` checks `lsusb` for NVIDIA VID `0955` + a recovery PID (`7023` / `7223` / `7423` / `7523` / `7e19`) and aborts if none is present. Run the `probe` stage to get the same check in isolation — useful for testing different cables / ports without losing the prepare-stage state:

```bash
make run -- -t probe
```

It prints every NVIDIA-vendor device on the bus, annotates which ones are in the recovery range, and exits 0 only when at least one is.

Recovery mode entry, step-by-step:

1. Disconnect power.
2. Connect USB-C between the Jetson **front panel** (button side) and the host.
3. Hold **REC** (middle button).
4. Connect power (or press Power).
5. Release REC after ~2 seconds.

Verify on the host:

```bash
lsusb | grep -i 'NVIDIA Corp'
```

| Output | Status |
|---|---|
| `0955:7023` / `7223` / `7423` / `7523` / `7e19` NVIDIA Corp. APX | Jetson in recovery (ready to flash) |
| `0955:<other PID>` | Booted into OS — re-enter recovery |
| (nothing) | Not detected — try a different cable / port / direct connection (no hub) |

Recovery mode runs over USB 2.0 (480 Mbps); this is normal — the USB 3 controller is inactive in APX.

### `clnt_create: RPC: Program not registered` / `NFS server is not running` / `Error 114`

The `flash` stage's `l4t_initrd_flash.sh` serves the flash payload to the Jetson's initrd over a local NFS export, but the container shares the host kernel and the host has not loaded the `nfsd` module:

```
 * Not starting NFS kernel daemon: no support in current kernel.
clnt_create: RPC: Program not registered
NFS server is not running
make: *** [Makefile:41: run] Error 114
```

Load it on the host (not inside the container), then re-run the flash:

```bash
sudo modprobe nfsd
make run -- -t flash
```

Persist across reboots with `echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf`. See [Prerequisites](#prerequisites). `flash.sh` now pre-checks this and aborts early with the same guidance.

### `ERROR: might be timeout in USB write` / `Return value 3`

Boot ROM communication stalls during USB bulk transfer:

```
Sending bct_br
ERROR: might be timeout in USB write.
Error: Return value 3
```

Stale USB endpoint state from a previous interrupted flash. A **hardware** power cycle back into APX recovery is required — power off, hold REC, reconnect power, release (`tegrarcm_v2 --reboot recovery` is not enough).

Also confirm `./script/host_setup.sh` ran this boot — it raises the USB buffer and disables autosuspend (see [Prerequisites](#prerequisites)).

### `Error: Error opening /dev/sda: No medium found` (microSD via USB reader)

Multi-slot combo readers expose each slot as a separate LUN, and the default `usb` alias maps to `sda1`. If the empty slot enumerates as `sda` and the card lands on `sdb`, the flash aborts before it ever touches the card:

```bash
$ lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN
sda    0B  Generic-  SD/MMC          usb     # empty
sdb  117.8G Generic-  Micro SD/M2    usb     # card actually here
```

**Finding the right `device_path`** (host enumeration usually mirrors the Jetson recovery initrd's, but is not guaranteed):

1. Plug the storage into the host with the rest of the USB tree the way it'll be at flash time.
2. Run `lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN`; the disk whose `SIZE` matches your card / SSD is the target.
3. Set `storage.device_path: <name>1` in `jetson.yaml` (e.g. `sdb1`) — partition `1` is what `l4t_initrd_flash.sh` expects.

If the first attempt still fails the same way, the Jetson initrd enumerated the bus differently; try the next letter (`sdb1` → `sdc1`, etc.). See [Configure `jetson.yaml`](#configure-jetsonyaml) for the full override semantics.

Other workarounds, in rough order of preference:

1. Use a single-slot microSD reader — those always enumerate as `sda`, the alias default.
2. Move the card to whichever slot maps to `/dev/sda` (use a microSD-to-SD adapter if needed).

### Flash hangs on APP partition (external storage)

Sustained large transfers over USB ethernet sometimes stall during the APP partition extraction step, eventually failing after a ~12 minute timeout. Options:

1. Flash to **eMMC** instead (`storage.device: emmc`), then `sudo apt install nvidia-jetpack` for the SDK components.
2. Use an **NVMe SSD** — direct PCIe is faster than USB-ethernet extraction.
3. Retry after a full power-cycle of the Jetson.
