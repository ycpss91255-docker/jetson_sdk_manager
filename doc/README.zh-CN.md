# Jetson SDK Manager Docker Environment

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

容器化 NVIDIA SDK Manager，用于烧录与配置 Jetson Orin 系列设备（AGX Orin、Orin NX、Orin Nano）。提供 CLI 与 GUI 两种 variant，以 `ubuntu:${BASE_IMAGE}` 为 base，通过公开的 CUDA apt repo 安装 SDK Manager。构建于 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 之上。

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## TL;DR

```bash
make build && make run -- -t cli
```

## 前置要求

- **Host OS**：x86_64 Linux
- **Docker Engine** >= v20.10.6
- **Host 软件包**（x86 host 烧录 ARM target 必须）：

  ```bash
  sudo apt-get install qemu-user-static binfmt-support
  sudo update-binfmts --enable
  ```

- **Jetson 设备**须进入 recovery mode（烧录时）

## 快速开始

```bash
make build -- -t cli             # 构建 CLI image
make run -- -t cli               # 运行 SDK Manager CLI
```

## 切换 Ubuntu 版本

默认 `ubuntu:24.04`。切到 `22.04`：

```bash
make setup -- set build.arg_4 BASE_IMAGE=ubuntu:22.04
make build -- -t cli
```

## 使用方式

```bash
make build -- -t cli             # 构建 CLI variant
make build -- -t gui             # 构建 GUI variant（X11）
make run -- -t cli               # CLI 交互模式
make run -- -t gui               # GUI 模式
make exec                        # 进入运行中的容器
make stop                        # 停止容器
```

### 支持的 Jetson Target

| Target 参数 | 设备 |
|------------|------|
| `JETSON_AGX_ORIN_TARGETS` | Jetson AGX Orin |
| `JETSON_ORIN_NX_TARGETS` | Jetson Orin NX |
| `JETSON_ORIN_NANO_TARGETS` | Jetson Orin Nano |

## 持久化数据

SDK Manager 下载文件和登录 session 持久化在 `data/`（已 gitignore）：

| Host 路径 | 容器路径 | 用途 |
|-----------|---------|------|
| `data/nvsdkm/` | `${HOME}/.nvsdkm` | 登录 session 缓存 |
| `data/downloads/` | `${HOME}/Downloads/nvidia/sdkm_downloads` | SDK 组件下载（~10-20 GB） |

## Smoke Tests

```bash
make build test
```

详见 [TEST.md](test/TEST.md)。
