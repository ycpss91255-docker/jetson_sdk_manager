#!/usr/bin/env bash
# Wraps `sdkmanager --cli` with the flash-only invocation that works inside Docker.
#
# The default SDK Manager flow installs Jetson SDK components after flashing,
# which requires NFS + iptables + USB device-mode forwarding from the host —
# none of which work reliably inside a container (the well-known "Flashing
# stuck at 99%" / "Device mode forwarding host setup failed" failures, see #21).
#
# We --deselect 'Jetson SDK Components' to flash the OS only, and let the
# Jetson install SDK components itself via OTA apt after first boot:
#
#   # On Jetson:
#   sudo apt update && sudo apt install -y nvidia-jetpack

set -euo pipefail

exec sdkmanager --cli \
  --action install \
  --login-type devzone \
  --product Jetson \
  --target-os Linux \
  --version 6.2.2 \
  --target JETSON_AGX_ORIN_TARGETS \
  --flash \
  --select 'Jetson Linux' \
  --deselect 'Jetson SDK Components' \
  --license accept \
  --stay-logged-in true \
  --auto \
  --exit-on-finish
