# Jetson Orin ファクトリーフラッシュコンテナ

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

コンテナ化された NVIDIA Jetson Linux（L4T）ファクトリーフラッシュワークフロー。Jetson Orin シリーズ（AGX Orin、Orin NX、Orin Nano）に対応。公式 BSP archive の `l4t_initrd_flash.sh --no-flash` / `--flash-only` を再現可能な 2 つの Docker stage にラップ。[`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 上に構築。

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

完全な説明（jetson.yaml スキーマ、各 stage の用途、トラブルシューティング）は [English README](../README.md) を参照。本ページは主要フローのクイックリファレンス。

---

## TL;DR

```bash
ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml   # preset を 1 つ選ぶ

make run -- -t prepare    # フェーズ 1：BSP ダウンロード + フラッシュイメージ生成（約 30 分）
# Jetson を APX recovery に入れる（REC を押しながら RESET をタップ）
make run -- -t flash      # フェーズ 2：Jetson に書き込み（約 10 分）
```

Jetson の初回起動後、デバイス上で JetPack コンポーネントをインストール：

```bash
sudo apt update && sudo apt install -y nvidia-jetpack
```

## なぜ SDK Manager ではなくファクトリーフラッシュか

NVIDIA SDK Manager の GUI / `--cli` フローは host 上の NFS server + `iptables` + USB device-mode forwarding に依存しており、Docker 内（`--privileged --network host` を付けても）では信頼性のある動作になりません。典型的な症状は [Flashing - 99% で停止](https://forums.developer.nvidia.com/t/docker-sdk-manager-flash-nx-struck-at-99/365066) — NVIDIA 公式 Docker image でも同じ問題が発生します。

本 repo はこの経路を完全に回避します：**prepare** stage は BSP 同梱の `l4t_initrd_flash.sh --no-flash` で host 側にフラッシュイメージを生成；**flash** stage は素の `tegrarcm_v2` USB 接続で `--flash-only` を実行して書き込みます。SDK Manager は **`inspector`** stage にカタログブラウザとして残していますが、Install ボタンは Docker 内で機能しません。

## 前提条件

- **Host OS**：x86_64 Linux、Docker Engine >= v20.10.6。
- **Host ファイルシステムは ext4 / xfs / btrfs**。NTFS / exFAT / `fuseblk` / FAT は setuid と ownership を保持できず、フラッシュ後の Jetson の `sudo` が起動を拒否します。`prepare.sh` は非 unix FS を検出するとアクションメッセージ付きで中止します。
- **QEMU binfmt**：`docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`（boot ごとに 1 回）。
- **USB buffer**：`echo 2048 | sudo tee /sys/module/usbcore/parameters/usbfs_memory_mb`（boot ごとに 1 回）。

## `jetson.yaml` の設定

トップレベルの `jetson.yaml` は `config/jetson/` 配下の preset への symlink です：

| Preset | ボード | ストレージ |
|---|---|---|
| `agx-orin-emmc.yaml` | AGX Orin devkit | eMMC |
| `agx-orin-nvme.yaml` | AGX Orin devkit | NVMe |
| `agx-orin-usb.yaml` | AGX Orin devkit | USB SSD |
| `orin-nx-nvme.yaml` | Orin NX devkit-super | NVMe |
| `orin-nano-nvme.yaml` | Orin Nano devkit-super | NVMe |
| `orin-nano-sd.yaml` | Orin Nano devkit-super | microSD（USB リーダー経由） |

切り替え：`ln -sf config/jetson/<preset>.yaml jetson.yaml`。

完全なスキーマは `config/jetson/_example.yaml` を参照。JetPack リリースを追加する場合は `config/jetson/_l4t_mapping.yaml` を編集。

## Stages

| Stage | 用途 | Jetson 接続必要 |
|---|---|---|
| `devel` | フラッシュツール。`make build` のデフォルト。 | いいえ |
| `prepare` | フェーズ 1 — フラッシュイメージ生成。 | いいえ |
| `flash` | フェーズ 2 — Jetson へ書き込み。 | **はい**、APX recovery |
| `inspector` | SDK Manager GUI（カタログ閲覧のみ）。 | いいえ |
| `devel-test` / `inspector-test` | Lint + smoke tests。 | いいえ |

## Clean コマンド

```bash
./script/clean.sh build    # 生成されたフラッシュイメージのみ削除
./script/clean.sh rootfs   # rootfs のみ削除
./script/clean.sh l4t      # Linux_for_Tegra/ ツリー全体を削除
./script/clean.sh all      # l4t + tarball も削除
```

JetPack バージョンの mismatch 時は `./script/clean.sh l4t` でリセット。

## Smoke Tests

```bash
make build test
```

詳細は [TEST.md](test/TEST.md) を参照。
