# jetson_sdk_manager

Containerized NVIDIA Jetson Linux (L4T) factory-flash workflow. Wraps `l4t_initrd_flash.sh --no-flash` / `--flash-only` from the official BSP archive into reproducible Docker stages, replacing SDK Manager dependence for the production flash path (see [ADR 0003](doc/adr/0003-skip-sdk-manager-for-flashing.md)).

## Language

### Configuration

**jetson.yaml**:
The top-level user-editable flash config. A symlink to one of the **preset** files. Bind-mounted into the container at `/etc/jetson.yaml`.
_Avoid_: config.yaml, settings.yaml

**preset**:
A pre-built variant of `jetson.yaml` stored under `config/jetson/*.yaml`, named `<board>-<storage>.yaml`. Users symlink the top-level `jetson.yaml` to a preset rather than editing free-form.
_Avoid_: profile, template, variant

**device alias**:
A short keyword that the user puts in `storage.device` (`emmc`, `nvme`, `usb`). Resolves through `_l4t_mapping.yaml::storage_alias_to_device` to a **storage mode** and a default **device_path**. Repo-internal vocabulary, not part of NVIDIA's BSP.
_Avoid_: storage type, storage shortcut

**device_path**:
A literal kernel device name (e.g. `sda1`, `sdb1`, `nvme0n1p1`) as seen by the **Jetson recovery initrd** — not the host kernel, though enumeration usually agrees. Set `storage.device_path` in jetson.yaml to override the alias-resolved default when a multi-slot reader enumerates the card as `sdb` instead of `sda`. Rejected when the **device alias** resolves to internal **storage mode**.
_Avoid_: device name, kernel name (ambiguous about which kernel)

### Flash workflow

**storage mode**:
`internal` for eMMC, `external` for NVMe / USB / SD card. NVIDIA's `l4t_initrd_flash.sh` takes a different command shape per mode (positional arg + several external-only flags). The repo's `prepare` / `flash` stages dispatch on this internally.
_Avoid_: storage type (overloaded with device alias), storage kind

**prepare stage**:
Phase 1 of factory flash. Downloads BSP + sample rootfs, runs `apply_binaries.sh`, `l4t_create_default_user.sh`, then `l4t_initrd_flash.sh --no-flash` to build flash images. No Jetson connected. Container entrypoint is `script/prepare.sh`.
_Avoid_: build stage, image stage, phase-1 stage

**flash stage**:
Phase 2 of factory flash. Writes the pre-built images to a Jetson in APX recovery via `l4t_initrd_flash.sh --flash-only`. Container entrypoint is `script/flash.sh`.
_Avoid_: write stage, deploy stage, phase-2 stage

**probe stage**:
Diagnostic. Scans host USB for NVIDIA-vendor (`0x0955`) devices, annotates which PIDs are in the Tegra APX recovery range, and exits non-zero unless at least one Jetson is in recovery. Config-free — does not read `jetson.yaml` and does not touch L4T data. Container entrypoint is `script/probe.sh`; reuses the vendor/PID list in `script/lib/usb.sh` that `flash.sh` also enforces.
_Avoid_: sanity stage, lsusb stage

**inspector stage**:
SDK Manager GUI shipped as a **catalog browser only**. Its Install button does not work inside Docker (see [ADR 0003](doc/adr/0003-skip-sdk-manager-for-flashing.md)); the entrypoint prints a banner saying so. Not part of the flash workflow.
_Avoid_: GUI stage, browser stage, sdkm stage

## Example dialogue

> **Dev:** I picked `agx-orin-usb.yaml` but flash dies on `Error opening /dev/sda: No medium found`.
>
> **Maintainer:** Your reader exposes the empty slot as sda. Set `storage.device_path: sdb1` in jetson.yaml to override the alias's default.
>
> **Dev:** Can I do the same trick on the emmc preset to flash a different device?
>
> **Maintainer:** No — `storage.device: emmc` resolves to internal storage mode, and there is no kernel device path to override. `device_path` is rejected when the device alias is internal. If you want to flash a USB SSD, change the alias to `usb` first.
>
> **Dev:** And the inspector stage?
>
> **Maintainer:** Inspector is just SDK Manager's catalog GUI. Don't use it to flash — its Install button is broken in Docker. The flash path is `prepare` then `flash`.
