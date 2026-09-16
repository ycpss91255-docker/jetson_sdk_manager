<!-- Deep-dive companion to README.md. Each entry: the exact error text, why it happens, what to do. -->
# Troubleshooting

Companion to the [README](../README.md). Run `./jetson status` first — most of the entries below are things it already points out.


### `prepare.sh` aborts: "L4T_ROOT ... is on ntfs/exfat/fuseblk"

`apply_binaries.sh` creates setuid binaries (`sudo`) and root-owned files. NTFS / exFAT / `fuseblk` / FAT silently drop both, which produces a flashed Jetson whose `sudo` refuses to start. This abort means `./data/jetson_l4t/` is on such a filesystem **and is not mounted** — i.e. `./script/host_setup.sh` has not run since boot. Run it; step 0 creates (first time) or re-mounts the in-repo ext4 image:

```bash
./script/host_setup.sh           # step 0: data/jetson_l4t.img → loop-mounted on data/jetson_l4t
findmnt ./data/jetson_l4t        # should show FSTYPE ext4, SOURCE /dev/loopN
make run -- -t prepare
```

Knobs (environment variables for `host_setup.sh`):

| Variable | Default | Effect |
|---|---|---|
| `L4T_STORE_SIZE` | `40G` | Logical size of the sparse image (minimum 20G; never shrinks an existing image). |
| `L4T_STORE_DIR` | unset | Use a directory on another ext4 / xfs / btrfs disk instead of an image; it is bind-mounted over `./data/jetson_l4t/` and recorded as `backend=directory-bind`. |
| `L4T_STORE_BACKEND` | auto | Force `loop-image` / `directory-bind` / `native` regardless of the detected filesystem (CI uses this). |

The mount is not persistent; re-run `host_setup.sh` after a reboot. `host_setup.sh` remembers the choice in `data/.l4t_store`, so a later run never re-formats: if the mount fails it points you at `sudo e2fsck -f data/jetson_l4t.img` rather than recreating the image.

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

Persist across reboots with `echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf`. See [README → Prerequisites](../README.md#prerequisites). `flash.sh` now pre-checks this and aborts early with the same guidance.

### Flash stalls mid-transfer / "Flashing - 99%" / `mount.nfs: No such file or directory`

The in-container flash (either path) stalling partway is almost always the **host's NetworkManager** DHCP-probing the Jetson's USB gadget interface, timing out, and removing the address mid-transfer — the root cause traced in [#48](https://github.com/ycpss91255-docker/jetson_sdk_manager/issues/48). Run `./script/nm_flash_guard.sh auto` before flashing (it marks the interface unmanaged, then re-enables NM when the board boots). If instead you see `mount.nfs: ... No such file or directory`, the host `/srv/jetson_l4t` bridge is missing — `./script/host_setup.sh` sets it up (step 5/7).

### "SSH ready", then nothing / `Either the device cannot mount the NFS server on the host or a flash command has failed`

The board booted the initrd, the host reached it over the `fc00:1:1::/48` link (`SSH ready`), and then the log stays silent for minutes before:

```
Error: Either the device cannot mount the NFS server on the host or a flash command has failed
```

**Cause** ([#101](https://github.com/ycpss91255-docker/jetson_sdk_manager/issues/101), AGX Orin 64 GB, 2026-09-16): the **host runs its own `nfs-kernel-server`** (`rpc.mountd`, `nfsdcld`, `rpcbind` from boot). The flash container (`--network host`) runs `exportfs` + its own `rpc.mountd`, but the kernel `nfsd` is shared, and its export upcalls got answered by the **host's** mountd using the host's empty `/etc/exports` → the board's `mount.nfs [fc00:1:1::1]:…/rootfs /mnt` hangs forever. Diagnose on the host while it hangs:

```bash
grep -E '^rc|^net' /proc/net/rpc/nfsd     # rc stuck at "rc 0 0 2" and the tcpconn count climbing = nobody answers
pgrep -a rpc.mountd                        # two of them: the host's (PID from boot) + the container's
exportfs -s                                # host export table: the L4T tree is not in it
```

**Fix**: export the three directories **on the host**, to the initrd's client range, with NVIDIA's permission string (`PERMISSION_STR` in `tools/kernel_flash/l4t_network_flash.func`). `./jetson flash` does exactly this before every flash (and `host_setup.sh` step 6/7 does it when a tree is prepared); by hand:

```bash
perm=rw,nohide,insecure,no_subtree_check,async,no_root_squash
L4T=/srv/jetson_l4t/JetPack_6.2.2_Linux_jetson-agx-orin-devkit/Linux_for_Tegra   # host-namespace path (the /srv bridge)
for d in "$L4T/rootfs" "$L4T/tools/kernel_flash/images" "$L4T/tools/kernel_flash/tmp"; do
  sudo exportfs -u "[fc00:1:1::/48]:$d" 2>/dev/null   # drop a previous (possibly stale) export first
  sudo exportfs -o "$perm" "[fc00:1:1::/48]:$d"
done
sudo exportfs -f                                        # flush the kernel export cache
```

`rc` jumps immediately and the flash continues. Two caveats learned the hard way:

- The export must be **`rw`**. The board mounts `rootfs` on `/mnt` and chroots into it; a default (`ro`) export dies with `mktemp: … Read-only file system`.
- **`mount.nfs: Stale file handle`** after a re-prepare (`clean.sh build`, then `./jetson prepare`): `tools/kernel_flash/images` was regenerated, so the old export points at a dead inode. `exportfs -u` + re-export + `exportfs -f` (the loop above) fixes it — which is why `./jetson flash` re-runs the export every time instead of trusting `host_setup.sh`'s.

`./jetson status` shows ⚠ *host rpc.mountd running but not exporting …* for this exact state. `host_teardown.sh` unexports. No `nfs-kernel-server` on the host at all? Then there is no competing mountd and the container's own export is enough — nothing to do.

### Flash waits in `Waiting for target to boot-up...` while dmesg loops `Cannot enable. Maybe the USB cable is bad?`

After `RCM-boot started` the board leaves RCM and comes back as the flash initrd's USB gadget (`0955:7035`, "Linux for Tegra", RNDIS). It only needs USB 2, but it also tries to train a SuperSpeed link on the same connector, and on some hosts (seen on an Ubuntu laptop, kernel 7.0, AGX Orin 64 GB, [#100](https://github.com/ycpss91255-docker/jetson_sdk_manager/issues/100)) that link never comes up. The xHCI SuperSpeed root hub then retries every few seconds, and each retry tears the working high-speed device down with it. `dmesg -w` shows the loop — note the two bus numbers, the SS half (`usb2-port3` here) and the HS half (`3-1`), which are the *same* physical connector:

```
usb 2-3: Device not responding to setup address.
usb 2-3: device not accepting address 17, error -71
usb usb2-port3: attempt power cycle
usb 3-1: New USB device found, idVendor=0955, idProduct=7035  Product: Linux for Tegra
rndis_host 3-1:1.0 usb0: register 'rndis_host' ...
usb 3-1: USB disconnect, device number 71            ← same second
usb usb2-port3: Cannot enable. Maybe the USB cable is bad?   (every 4 s)
```

`l4t_initrd_flash` sits in `Waiting for target to boot-up...` until its timeout; a hub vs. a direct port and a longer timeout make no difference, and it is not the cable. The fix is to switch the SuperSpeed half of that connector off on the host for the duration of the flash — the high-speed half keeps working and the board stays enumerated. `./jetson flash` does this for you via `./script/usb_ss_guard.sh auto` (it finds the recovery device's port, pairs it with the one SuperSpeed root-hub port that reports the same `location`, writes `disable=1` there, records it under `/run/usb-ss-guard/`, and a root watcher writes `0` back when the board boots as `0955:7020` or after 30 min; `./jetson status` shows ⚠ while a port is parked; `./jetson teardown` restores it too). If the flash is already looping, running `./script/usb_ss_guard.sh disable` mid-flash works as well — the board re-enumerates the same second.

The watcher is started as root with `sudo -n` right after `disable` (while the sudo credential is fresh), so it needs no terminal later. If sudo refuses at that moment (credential expired, `timestamp_timeout=0`), `auto` says so and the port simply stays parked: run `./script/usb_ss_guard.sh enable` after the flash (`./jetson teardown` does), or reboot — the sysfs setting and the record under `/run` are both boot-scoped, so a reboot always restores the connector.

Manual fallback (the two ports of one connector share a `location`; pick the one the Jetson is *not* on):

```bash
grep . /sys/bus/usb/devices/usb*/*-0:1.0/usb*-port*/location   # find the two ports with the same value
echo 1 | sudo tee /sys/bus/usb/devices/usb2/2-0:1.0/usb2-port3/disable   # the SuperSpeed half
# ... flash ...
echo 0 | sudo tee /sys/bus/usb/devices/usb2/2-0:1.0/usb2-port3/disable   # or just reboot
```

`usb_ss_guard.sh` says so and does nothing when there is no SuperSpeed sibling (a USB-2-only cable, or the board behind a hub whose ports have no ACPI `location`) or when the kernel exposes no per-port `disable` attribute.

### SDK Manager: "Device mode forwarding host setup failed"

This is **not** a fundamental Docker limitation (an earlier README claimed so — it was wrong). SDK Manager's `device_mode_host_setup.sh` needs `iptables` (NAT MASQUERADE) and `dig` (a DNS reachability probe); both now ship in the `sdkm-base` layer, so the `cli` / `gui` stages clear this step. If it still fails, confirm you ran `./script/host_setup.sh` + `./script/nm_flash_guard.sh auto` and are signed in to your NVIDIA Developer account. Context: [#48](https://github.com/ycpss91255-docker/jetson_sdk_manager/issues/48).

### SDK Manager GUI: component install hangs (a step stuck at a fixed %)

SDK Manager's on-device SDK-component install can hang in the GUI — a step (often "Additional Setups", or any package) sits at a fixed percentage and the "taking longer than expected" dialog keeps reappearing — even though the device-side step already finished and the board has working network (`ping 8.8.8.8` from the board succeeds). This is an SDK Manager (upstream) progress-tracking flakiness, **not a flash failure**: the OS is already flashed and the board boots.

You do not need SDK Manager to finish the component install. The flashed board already has the NVIDIA L4T apt source configured, so install the full JetPack SDK directly on the board — the same packages, and exactly what the factory path does:

```bash
ssh <user>@192.168.55.1
sudo apt update && sudo apt install -y nvidia-jetpack
```

This is one more reason the factory `prepare` / `flash` path is the documented default: it installs the SDK components on the booted board via apt, with no GUI step to hang.

### `Error: No Board Spec. and no target connected, exit.` (prepare, step 10/10)

NVIDIA's `flash.sh` needs the board spec — `BOARDID`, `FAB`, `BOARDSKU`, `BOARDREV` — to lay out the images, and unless you export those it reads them from the board's EEPROM over the recovery USB link. So prepare's last step needs a Jetson in recovery, exactly like flash does. Put the board in recovery and re-run `./jetson prepare` (it resumes at 10/10). If you know the spec and want to prepare with no board attached: export the four variables and run `./jetson prepare --no-board`.

### `ERROR: might be timeout in USB write` / `Return value 3`

Seen at the first RCM write of either **flash** or **prepare's step 10/10** (`Sending bct_br` → `Parsing board information failed` → `failed to generate images`). Boot ROM communication stalls during USB bulk transfer:

```
Sending bct_br
ERROR: might be timeout in USB write.
Error: Return value 3
```

One possible cause is Boot ROM USB state left over from a previous interrupted attempt (#10); a **hardware** power cycle clears that — power off, hold REC, reconnect power, release (`tegrarcm_v2 --reboot recovery` is not enough) — so do it first, then re-run the same command; prepare resumes where it stopped. If it persists after a clean power cycle, work through the USB path: a direct host port, another cable, host USB settings (`./jetson status` checks autosuspend / usbfs buffer). In the setup reported in #48, switching between a hub and a direct port did not change the result, so try the power cycle first.

Also confirm `./script/host_setup.sh` ran this boot — it raises the USB buffer and disables autosuspend (see [README → Prerequisites](../README.md#prerequisites)).

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

If the first attempt still fails the same way, the Jetson initrd enumerated the bus differently; try the next letter (`sdb1` → `sdc1`, etc.). See [README → Configure `jetson.yaml`](../README.md#configure-jetsonyaml) for the full override semantics.

Other workarounds, in rough order of preference:

1. Use a single-slot microSD reader — those always enumerate as `sda`, the alias default.
2. Move the card to whichever slot maps to `/dev/sda` (use a microSD-to-SD adapter if needed).

### Flash hangs on APP partition (external storage)

Sustained large transfers over USB ethernet sometimes stall during the APP partition extraction step, eventually failing after a ~12 minute timeout. Options:

1. Flash to **eMMC** instead (`storage.device: emmc`), then `sudo apt install nvidia-jetpack` for the SDK components.
2. Use an **NVMe SSD** — direct PCIe is faster than USB-ethernet extraction.
3. Retry after a full power-cycle of the Jetson.
