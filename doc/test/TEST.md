# TEST.md

**1 test** total.

## test/smoke/orin_install_env.bats (1)

| Test | Description |
|------|-------------|
| `entrypoint.sh exists and is executable` | Entrypoint check |

## What CI actually proves

CI is build-and-lint plus a tiny smoke suite. It runs on GitHub-hosted x86_64 runners with **no Jetson attached**, so nothing below the line "real flash" is exercised:

- Image build for every Dockerfile stage.
- `shellcheck` + `hadolint` lint.
- The `bats` smoke suite (this file).
- `sdkmanager --ver` (the `cli-test` / `gui-test` stages).

CI does **NOT** flash a board, serve NFS to a device, or write eMMC / NVMe / USB / SD. Treat green CI as "it builds and the scripts are well-formed", not "it flashes".

## Verification status (per preset)

Mirrors the [Verification status](../../README.md#verification-status) table in the README.

| Preset | Status |
|---|---|
| `agx-orin-emmc.yaml` | verified on hardware 2026-06, JetPack 6.2.2 |
| `agx-orin-nvme.yaml` | config-validated only |
| `agx-orin-usb.yaml` | config-validated only |
| `orin-nx-nvme.yaml` | config-validated only |
| `orin-nano-nvme.yaml` | config-validated only |
| `orin-nano-sd.yaml` | config-validated only |

"config-validated only" = the preset parses, resolves its aliases, and builds flash images, but the full `flash` to that board + storage has not been confirmed on real hardware.

## HITL-ONLY paths (CI cannot verify these)

The following steps require **hardware in the loop** (a Jetson in APX recovery on a real host). None of them run in CI; each can only be checked by a human flashing a board:

- **eMMC discard patch** — the on-device flash script's skip-eMMC-discard behaviour. Only observable against real eMMC silicon.
- **Device-served NFS flash** — the `flash` stage serving the payload to the Jetson's initrd over a local NFS export across the `tegrarcm_v2` USB link. Needs the host `nfsd` module and a booted-to-initrd device.
- **SDK Manager flash** — a real `sdkmanager --cli` / GUI flash, including its device-mode forwarding (`iptables` + `dig`). CI only smokes `sdkmanager --ver`.
- **The `/srv/jetson_l4t` bridge** — `host_setup.sh` bridging the flash export path into the host mount namespace so the host kernel `nfsd` can serve the container-only bind mount. Only meaningful during an actual device-served flash.

Because these are HITL-only, a passing CI run says nothing about them; sign-off for each comes from the per-preset verification table above.
