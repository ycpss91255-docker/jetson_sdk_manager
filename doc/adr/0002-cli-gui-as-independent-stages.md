# CLI and GUI variants as independent Dockerfile stages

CLI and GUI are implemented as independent Dockerfile stages (`FROM devel AS cli`, `FROM devel AS gui`) rather than a single `devel` stage controlled by a `VARIANT` build ARG. The `gui` stage has a substantive `RUN apt-get install` step for X11 client libraries, making it architecturally distinct from `cli` (which only sets CMD). Independent stages produce cleaner separation and smaller CLI images. Trade-off: the base template's `build-worker.yaml` only builds the hardcoded `devel-test → devel → runtime-test → runtime` pipeline and cannot build extra stages — an `extra_stages` input has been proposed upstream (ycpss91255-docker/base#415). Until that lands, CI coverage for the `gui` and `gui-test` stages requires a workaround or waits for the upstream feature.

## Considered Options

- **ARG VARIANT within devel stage**: fully compatible with existing `build-worker.yaml` CI matrix, but mixes GUI dependencies into the CLI image when building the gui variant, and conditional `RUN` / `CMD` logic is less readable.
- **Independent stages** (chosen): clean separation, smaller images per variant, follows the `isaac` repo pattern (`headless` / `gui`), but requires upstream CI support for extra stage builds.
