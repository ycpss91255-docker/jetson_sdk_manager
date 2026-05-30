# Skip SDK Manager for the flash path; use l4t_initrd_flash directly

NVIDIA SDK Manager flashes a Jetson by running an NFS server on the host and exporting the rootfs to the device over a USB device-mode link, bridged through the host's network stack via `iptables`. Inside Docker (even with `--privileged --network host`) this combination is non-functional: NFS server cannot bind reliably, `iptables` rules from inside the container do not always reach the host's `nftables`, and `usb-gadget` device-mode forwarding fails. The visible symptom is the well-known [Flashing - 99% stall](https://forums.developer.nvidia.com/t/docker-sdk-manager-flash-nx-struck-at-99/365066) that affects NVIDIA's own Docker image too. The production flash path is therefore implemented on top of the BSP's `l4t_initrd_flash.sh --no-flash` / `--flash-only`, which only needs a plain `tegrarcm_v2` USB link — split into the **prepare** stage (host-side image build, no Jetson) and **flash** stage (write to Jetson in APX recovery). SDK Manager is retained as the **inspector** stage for browsing the JetPack component catalog, with a banner explaining the Install button is broken inside Docker.

## Considered Options

- **Fix SDK Manager in Docker**: every layer (NFS, iptables, usb-gadget) requires kernel-level host privileges that don't survive container boundaries; multiple upstream and community attempts have not produced a working solution.
- **Use the `flash.sh` classic path** (`./flash.sh <board> mmcblk0p1`): works only for eMMC; cannot reach external storage; superseded by `l4t_initrd_flash.sh` in R36.x.
- **`l4t_initrd_flash.sh` two-phase** (chosen): NVIDIA's own production / factory flash workflow, no NFS or iptables, works inside Docker with just `tegrarcm_v2` over USB.

## Consequences

- Users no longer install JetPack SDK components during flash. After first boot, they run `sudo apt install -y nvidia-jetpack` on the Jetson itself — same package set SDK Manager would have pushed, pulled directly by the Jetson via NVIDIA's OTA apt repository.
- The `prepare` stage needs a host filesystem that preserves `setuid` and ownership for `apply_binaries.sh` (ext4 / xfs / btrfs). NTFS / exFAT / `fuseblk` / FAT silently strip both; `script/prepare.sh` aborts there with an action message (`JETSON_ALLOW_NON_UNIX_FS=1` overrides as an opt-in for experimentation).
- The two-phase split (`prepare` then `flash`) lets users iterate on flash without rebuilding the ~30-minute image set on every attempt.
