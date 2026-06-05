# Restore SDK Manager as a best-effort cli / gui path (amends ADR-0003)

[ADR-0003](0003-skip-sdk-manager-for-flashing.md) chose `l4t_initrd_flash.sh` as the production flash path and kept SDK Manager only as an `inspector` (catalog-browser) stage, on the premise that SDK Manager's flash was **fundamentally broken inside Docker** (NFS, `iptables`, USB device-mode forwarding). Hands-on testing disproved the "fundamentally broken" framing:

- The mid-flash stall was the **host's NetworkManager** DHCP-probing the Jetson USB gadget link and removing the address mid-transfer — not a container limitation. Fixed host-side by `script/nm_flash_guard.sh` (#48 / #49).
- SDK Manager's "Device mode forwarding host setup failed" was simply **missing `iptables` + `dnsutils`** in the image. Added in the shared `sdkm-base` layer (#51).

With those two fixes plus an NVIDIA login, SDK Manager can complete a flash in a container. This ADR therefore amends ADR-0003: the **default is unchanged** (factory `prepare` / `flash`, CI-guarded), but SDK Manager is restored as two **best-effort** stages rather than a browser-only dead end.

## Decision

- Keep factory `prepare` / `flash` as the supported, CI-guarded default (ADR-0003 stands).
- Ship SDK Manager as `cli` (`sdkmanager --cli`) and `gui` (graphical client) stages on a shared `sdkm-base` (`sdkmanager` + `iptables` + `dnsutils`).
- Replace the `inspector` stage (and its "Install is broken" banner) with `gui`; catalog browsing is just "launch the GUI and don't flash".
- Tier SDK Manager as **best-effort**: CI builds the stages and smokes `sdkmanager --ver`, but a real SDK Manager flash is manual/HITL and may drift with NVIDIA upstream.

## Consequences

- Users who prefer NVIDIA's own tool, or want the JetPack `.deb` catalog, have a working in-container path — after the same host prep as factory flash (`host_setup.sh`, `nm_flash_guard.sh auto`, NVIDIA login).
- `devel` stays slim: SDK Manager + CUDA repo live only in `sdkm-base` and its descendants, not the base flash image.
- The non-unix-FS setuid guard (`lib/fs.sh`) now covers the SDK Manager data dir too (`sdkm-entrypoint.sh`), since SDK Manager extracts a setuid `sudo` under `./data/nvidia_sdk` with the same broken-sudo risk as the factory path.
