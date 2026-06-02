# Jetson Orin 工厂烧录容器

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

容器化的 NVIDIA Jetson Linux（L4T）工厂烧录流程，支持 Jetson Orin 系列设备（AGX Orin、Orin NX、Orin Nano）。将官方 BSP archive 中的 `l4t_initrd_flash.sh --no-flash` / `--flash-only` 包装为两个可重现的 Docker stage。构建于 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 之上。

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

完整说明（jetson.yaml schema、各 stage 用途、疑难排解）见 [English README](../README.md) 或 [繁體中文 README](README.zh-TW.md)。本页是常用流程的速查。

---

## TL;DR

```bash
ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml   # 选一个 preset

make run -- -t prepare    # 阶段 1：下载 BSP + 生成烧录 image（约 30 分钟）
# 将 Jetson 进入 APX recovery（按住 REC + 点 RESET）
make run -- -t flash      # 阶段 2：写入 Jetson（约 10 分钟）
```

Jetson 首次开机后，在设备上安装 JetPack 组件：

```bash
sudo apt update && sudo apt install -y nvidia-jetpack
```

## 为什么用工厂烧录而非 SDK Manager

NVIDIA SDK Manager 的 GUI 与 `--cli` 流程依赖 host 上的 NFS server + `iptables` + USB device-mode forwarding，这些在 Docker 内（即使加上 `--privileged --network host`）无法可靠运作。典型症状是 [Flashing - 99% 卡死](https://forums.developer.nvidia.com/t/docker-sdk-manager-flash-nx-struck-at-99/365066) — NVIDIA 官方 Docker image 也有同样问题。

本 repo 直接绕过此路径：**prepare** stage 在 host 端用 `l4t_initrd_flash.sh --no-flash` 生成烧录 image；**flash** stage 通过 `tegrarcm_v2` USB 连线以 `--flash-only` 写入。SDK Manager 仍保留于 **`inspector`** stage 作为目录浏览器，但 Install 按钮在 Docker 内仍然失效。

## 前置要求

- **Host OS**：x86_64 Linux，Docker Engine >= v20.10.6。
- **Host 文件系统须为 ext4 / xfs / btrfs**。NTFS / exFAT / `fuseblk` / FAT 会丢掉 setuid 与 ownership，导致烧录后 Jetson 的 `sudo` 拒绝启动。`prepare.sh` 会在偵測到非 unix FS 时以 action 讯息中止。
- **QEMU binfmt**：`docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`（每次开机一次）。
- **USB buffer**：`echo 2048 | sudo tee /sys/module/usbcore/parameters/usbfs_memory_mb`（每次开机一次）。
- **USB auto-suspend**：连接 Jetson 的端口必须关闭，否则 `tegrarcm_v2` 可能在写入中途卡死。最简单是本次开机全局关掉：`echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend`（每次开机一次）。

## 设定 `jetson.yaml`

顶层的 `jetson.yaml` 是指向 `config/jetson/` 下某个 preset 的 symlink：

| Preset | 板子 | 储存 |
|---|---|---|
| `agx-orin-emmc.yaml` | AGX Orin devkit | eMMC |
| `agx-orin-nvme.yaml` | AGX Orin devkit | NVMe |
| `agx-orin-usb.yaml` | AGX Orin devkit | USB SSD |
| `orin-nx-nvme.yaml` | Orin NX devkit-super | NVMe |
| `orin-nano-nvme.yaml` | Orin Nano devkit-super | NVMe |
| `orin-nano-sd.yaml` | Orin Nano devkit-super | microSD（USB reader） |

切换：`ln -sf config/jetson/<preset>.yaml jetson.yaml`。

完整 schema 见 `config/jetson/_example.yaml`。新增 JetPack 版本编辑 `config/jetson/_l4t_mapping.yaml`。

## Stages

| Stage | 用途 | 需连 Jetson |
|---|---|---|
| `devel` | 烧录工具。`make build` 预设。 | 否 |
| `prepare` | 阶段 1 — 生成烧录 image。 | 否 |
| `flash` | 阶段 2 — 写入 Jetson。 | **是**，APX recovery |
| `inspector` | SDK Manager GUI（仅目录浏览）。 | 否 |
| `devel-test` / `inspector-test` | Lint + smoke tests。 | 否 |

## Clean 指令

```bash
./script/clean.sh build    # 只移除生成的烧录 image
./script/clean.sh rootfs   # 只移除 rootfs
./script/clean.sh l4t      # 移除整个 Linux_for_Tegra/ 树
./script/clean.sh all      # l4t + 移除 tarball
```

JetPack 版本 mismatch 时跑 `./script/clean.sh l4t` 重置。

## Smoke Tests

```bash
make build test
```

详见 [TEST.md](test/TEST.md)。
