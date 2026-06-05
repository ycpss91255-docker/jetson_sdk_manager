# Dockerfile - Jetson factory-flash dev container
#
# Stages:
#   sys             - User/group, locale, timezone
#   devel-base      - Development tools and packages
#   devel           - Flash tooling (l4t_initrd_flash deps) + entrypoint
#   devel-test      - Lint + bats smoke test (ephemeral)
#   prepare         - NVIDIA factory flash phase 1 (host-side image build)
#   flash           - NVIDIA factory flash phase 2 (write to Jetson over USB)
#   probe           - Diagnostic: scan USB for Jetson APX recovery device
#   inspector       - SDK Manager GUI for catalog browsing (NOT flashing)
#   inspector-test  - inspector sanity check (ephemeral)

ARG BASE_IMAGE="ubuntu:22.04"
ARG TEST_TOOLS_IMAGE="test-tools:local"

############################## sys ##############################
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS sys

ARG USER_NAME="user"
ARG USER_GID=1000
ARG USER_UID=1000
ARG USER_GROUP="user"
ARG TZ="Asia/Taipei"
ARG APT_MIRROR_UBUNTU="tw.archive.ubuntu.com"
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-x", "-euo", "pipefail", "-c"]

RUN sed -i "s@archive.ubuntu.com@${APT_MIRROR_UBUNTU}@g" /etc/apt/sources.list || true; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        tzdata \
        locales \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG="en_US.UTF-8" && \
    ln -snf /usr/share/zoneinfo/"${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV TZ="${TZ}"

# Create user (handle UID/GID conflicts)
RUN if getent group "${USER_GID}" >/dev/null; then \
        groupmod -n "${USER_GROUP}" "$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${USER_GID}" "${USER_GROUP}"; \
    fi && \
    if getent passwd "${USER_UID}" >/dev/null; then \
        usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m \
            "$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
    else \
        useradd -m -l -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"; \
    fi && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

############################## devel-base ##############################
FROM sys AS devel-base

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sudo \
        git \
        vim \
        tmux \
        terminator \
        curl \
        wget \
        python3 \
        python3-pip \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## devel ##############################
FROM devel-base AS devel

ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
# Layered config/ override (template#254): two sequential COPYs into
# /tmp/config/. The first brings .base/config/ defaults; the
# second overlays <repo>/config/ on top. File-level merge -- files in
# <repo>/config/ replace same-path files in /tmp/config/; files only
# in .base/config/ stay; files only in <repo>/config/ are added.
# Mental model is the same as setup.conf section-replace, just at
# file granularity. <repo>/config/ becomes opt-in (init.sh seeds an
# empty .gitkeep for new repos, not the full tree); existing repos
# with a full <repo>/config/ snapshot from earlier seed continue to
# work (their copy overrides every template default, identical to
# pre-v0.22.0 behaviour). Trim <repo>/config/ files that match
# template default to start receiving template-side improvements.
ARG CONFIG_SRC="config"

ARG DEBIAN_FRONTEND=noninteractive

# Flash prerequisites for prepare.sh / flash.sh
# (tools/kernel_flash/l4t_initrd_flash.sh). The CUDA repo + sdkmanager
# install moved to the inspector stage -- the production flash flow
# uses the factory workflow (prepare + flash stages) and no longer
# depends on SDK Manager at the devel layer.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        abootimg android-sdk-libsparse-utils bc binfmt-support \
        binutils cpio cpp cryptsetup device-tree-compiler \
        dmsetup dosfstools file gdisk iproute2 iputils-ping \
        kpartx lbzip2 libxml2-utils lz4 netcat-openbsd \
        nfs-kernel-server openssh-client openssl parted pigz \
        pv python3-yaml python-is-python3 qemu-user-static \
        rsync sshpass udev usbutils uuid-runtime whois \
        xmlstarlet xxd zstd zlib1g && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    grep -q '^root' /etc/sudoers || echo "root ALL=(ALL:ALL) ALL" >> /etc/sudoers

# mikefarah/yq -- the Go binary, not the Python kislyuk/yq wrapper.
# script/lib/yaml.sh + script/lib/volume.sh rely on `yq -i` (in-place
# edit) which only the Go version supports. Jammy/Noble apt repos
# don't ship it, so pin a release and grab the static binary directly.
ARG YQ_VERSION="v4.44.3"
ARG TARGETARCH="amd64"
RUN wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
        -O /usr/local/bin/yq && \
    chmod 0755 /usr/local/bin/yq && \
    yq --version

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
# Host-side log tee helper (#328 / #368). Source from
# script/entrypoint.sh with a single un-guarded line:
#   . /usr/local/lib/base/logging.sh
# The helper is a no-op when LOG_FILE_PATH is unset, so the source
# line is safe to add unconditionally -- repos that haven't opted
# into [logging] local_path stay unaffected. In-image path (vs the
# bind-mounted .base/) avoids two failure modes: build-time smoke
# crashes when $USER is unset, and multi-repo workspaces where
# WS_PATH is the workspace parent rather than the repo root.
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
# Layer 1: .base/config/ defaults (subtree-managed, updates with
# .base/upgrade.sh).
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
# Layer 2: <repo>/config/ overrides (per-repo, survives subtree
# pull). Files here overlay matching paths from layer 1.
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"

USER "${USER}"

# WORKDIR is a Docker directive: it interpolates build-time ARG / ENV
# only, not shell-time $HOME. Without this explicit ENV, the
# `WORKDIR "${HOME}/work"` below silently collapses to /work (BuildKit
# emits `WARN: UndefinedVar`) and `docker inspect` reports the wrong
# WorkingDir. Refs #334.
ENV HOME="/home/${USER_NAME}"

# Setup shell, terminator, tmux. The bashrc append picks up the
# bashrc.d bootstrap loop (template#254) which sources any *.sh
# drop-ins under ~/.bashrc.d/ at interactive shell start.
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}"

# (Optional) Repo-local Dockerfile-internal build helpers. Put any
# shell helpers that should run during `docker build` under
# <repo>/script/docker/<name>.sh, then COPY them into a build-time
# scratch location and RUN them. Cleanup keeps the final image lean.
# Runtime helpers (entrypoint, ros bringup, ...) stay under
# <repo>/script/ as before; the two classes are deliberately split.
#
# Example (uncomment and adapt):
#COPY --chmod=0755 script/docker/build_helper.sh /tmp/build_helper.sh
#RUN /tmp/build_helper.sh && rm /tmp/build_helper.sh

WORKDIR "${HOME}/work"

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

############################## devel-test ##############################
# Resolves to test-tools:local (local build.sh) or ghcr.io/.../test-tools:vX.Y.Z (CI).
# hadolint ignore=DL3006
FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage

FROM devel AS devel-test

USER root

# Lint tools (from pre-built test-tools image; see TEST_TOOLS_IMAGE at top)
COPY --from=test-tools-stage /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=test-tools-stage /usr/local/bin/hadolint /usr/local/bin/hadolint

# Lint: ShellCheck (.sh) + Hadolint (Dockerfile)
COPY .hadolint.yaml /lint/.hadolint.yaml
COPY Dockerfile /lint/Dockerfile
# Post-#330 the seven user-facing wrappers live under <repo>/script/;
# pull them in via that directory (BuildKit follows the ../.base/...
# symlinks since the target sits inside the build context).
COPY script/*.sh /lint/
# Helpers sourced by the wrappers. Must sit next to them so
# build.sh / run.sh / exec.sh / stop.sh / setup.sh can source _lib.sh
# (which in turn sources i18n.sh); setup.sh also sources _tui_conf.sh.
# Post-#406 all helpers live under lib/ — single COPY preserves the
# directory layout. The wrappers themselves live under wrapper/.
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper /lint/wrapper
# Lint coverage for repo-local Dockerfile-internal build helpers (#275).
# Uncomment if your repo has any <repo>/script/docker/*.sh build helpers
# (see the commented example in the devel stage above); the COPY brings
# them into /lint/ so ShellCheck catches issues at build time.
#COPY script/docker/*.sh /lint/
# Repo-local runtime scripts (prepare/flash/clean + lib/) — separate
# COPY to preserve the script/lib/ subdir for source-path resolution.
COPY script/lib /lint/script_lib
RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh && \
    shellcheck -S warning \
        /lint/prepare.sh /lint/flash.sh /lint/probe.sh /lint/clean.sh \
        /lint/inspector-entrypoint.sh /lint/nm_flash_guard.sh \
        /lint/init_data_dirs.sh /lint/entrypoint.sh \
        /lint/script_lib/*.sh
WORKDIR /lint
RUN hadolint Dockerfile

# Bats (from pre-built test-tools image; see TEST_TOOLS_IMAGE at top)
COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Runtime-layout copy of the prepare/flash entry scripts + their lib/
# siblings, mirroring the path used by the prepare and flash stages
# (/opt/jetson_install/). Separate from the /lint/ rename-shuffle COPY
# above (which exists to feed shellcheck without making /lint/lib clash
# with the shellchecked /lint/lib from .base/). Used by the storage
# resolver + flash dispatch bats integration tests to drive prepare.sh
# and flash.sh end-to-end.
COPY --chmod=0755 script/prepare.sh /opt/jetson_install/prepare.sh
COPY --chmod=0755 script/flash.sh /opt/jetson_install/flash.sh
COPY --chmod=0755 script/probe.sh /opt/jetson_install/probe.sh
# Host-side flash guard (#50 auto mode) — copied so its bats unit test
# exercises the watcher instead of skipping. Sources lib/usb.sh below.
COPY --chmod=0755 script/nm_flash_guard.sh /opt/jetson_install/nm_flash_guard.sh
COPY --chmod=0755 script/lib /opt/jetson_install/lib

# Smoke test (shared from template + repo-specific)
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/

ARG USER
USER "${USER}"

RUN bats /smoke_test/

############################## inspector ##############################
# SDK Manager GUI for browsing the JetPack component catalog and
# downloading individual .deb packages. NOT for flashing -- the GUI's
# Install button is fundamentally broken inside Docker (NFS server,
# iptables, USB device-mode forwarding all fail even with
# --privileged --network host). The production flash path uses the
# prepare + flash stages below; inspector-entrypoint.sh prints a
# warning banner explaining this before launching the GUI.
FROM devel AS inspector

USER root

ARG DEBIAN_FRONTEND=noninteractive

# CUDA repo + SDK Manager itself. yq for /etc/jetson.yaml lookup is
# already in devel (see the GitHub-release install there).
# hadolint ignore=DL4006,SC1091
RUN . /etc/os-release && \
    UBUNTU_VER=$(echo "${VERSION_ID}" | tr -d '.') && \
    wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VER}/x86_64/cuda-keyring_1.1-1_all.deb" && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        sdkmanager \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY config/packages/ /tmp/packages/

# X11 / GUI client libs from the per-distro list.
# hadolint ignore=DL4006,SC2046
RUN . /etc/os-release && \
    pkg_list="/tmp/packages/${VERSION_CODENAME}.txt" && \
    if [ ! -f "${pkg_list}" ]; then \
        echo "ERROR: no package list for ${VERSION_CODENAME} (${PRETTY_NAME})" && \
        echo "Create config/packages/${VERSION_CODENAME}.txt and rebuild." && \
        exit 1; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        $(grep -v '^\s*#' "${pkg_list}" | grep -v '^\s*$' | tr '\n' ' ') && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/packages/

COPY --chmod=0755 script/inspector-entrypoint.sh /usr/local/bin/inspector-entrypoint.sh

ARG USER
USER "${USER}"

CMD ["/usr/local/bin/inspector-entrypoint.sh"]

############################## inspector-test ##############################
FROM inspector AS inspector-test

RUN sdkmanager --ver

############################## prepare ##############################
# Phase 1 of the NVIDIA factory flash workflow. Reads /etc/jetson.yaml
# (bind-mounted from the repo's jetson.yaml symlink at runtime) and
# writes flash images to the jetson_l4t Docker volume. No Jetson
# needed. See script/prepare.sh + doc/Flash_Workflow.md.
#
# Build-time COPY of _l4t_mapping.yaml — keeps the prepare image
# self-contained at runtime (the user-editable jetson.yaml is the only
# bind mount). When NVIDIA adds a new JetPack release, update
# config/jetson/_l4t_mapping.yaml in this repo, commit, and rebuild.
FROM devel AS prepare

USER root

# Tools (yq, lbzip2, tar, wget, sudo, openssh-client, etc.) already
# in devel. This stage layers in only the YAML mapping + entry script.
#
# `/etc/jetson/` must be pre-created with traversable perms; otherwise
# BuildKit's --chmod=0644 flag is applied to BOTH the file AND the
# implicitly-created parent directory, leaving /etc/jetson/ as 0644
# (drw-r--r--) which blocks non-root users from chdir-ing in to read
# the file. Same fix needed in the flash stage below.
RUN mkdir -p /etc/jetson && chmod 0755 /etc/jetson
COPY --chmod=0644 config/jetson/_l4t_mapping.yaml /etc/jetson/_l4t_mapping.yaml
# Co-locate the entry script with its lib/ siblings — script/prepare.sh
# sources script/lib/*.sh via a relative `${BASH_SOURCE[0]}` lookup.
COPY --chmod=0755 script/prepare.sh /opt/jetson_install/prepare.sh
COPY --chmod=0755 script/lib /opt/jetson_install/lib

ARG USER
USER "${USER}"

CMD ["/opt/jetson_install/prepare.sh"]

############################## flash ##############################
# Phase 2: write the volume's pre-generated images to a Jetson in APX
# recovery. Requires Jetson connected over USB device-mode. See
# script/flash.sh + doc/Flash_Workflow.md.
FROM devel AS flash

USER root

# yq already in devel. This stage layers in only the YAML mapping
# + entry script. See prepare stage above re. /etc/jetson/ pre-mkdir.
RUN mkdir -p /etc/jetson && chmod 0755 /etc/jetson
COPY --chmod=0644 config/jetson/_l4t_mapping.yaml /etc/jetson/_l4t_mapping.yaml
COPY --chmod=0755 script/flash.sh /opt/jetson_install/flash.sh
COPY --chmod=0755 script/lib /opt/jetson_install/lib

ARG USER
USER "${USER}"

CMD ["/opt/jetson_install/flash.sh"]

############################## probe ##############################
# Diagnostic stage: scan host USB for a Jetson in APX recovery. No
# jetson.yaml, no L4T mapping, no Jetson required at build time —
# probe is intentionally config-free so users can sanity-check the
# host ↔ Jetson link before they commit to the prepare/flash flow.
# See script/probe.sh + script/lib/usb.sh.
FROM devel AS probe

USER root

# lsusb (usbutils) already in devel. Only the entry script + the
# shared usb / errors helpers need to land in this stage.
COPY --chmod=0755 script/probe.sh /opt/jetson_install/probe.sh
COPY --chmod=0755 script/lib /opt/jetson_install/lib

ARG USER
USER "${USER}"

CMD ["/opt/jetson_install/probe.sh"]
