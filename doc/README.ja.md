# Jetson SDK Manager Docker Environment

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

コンテナ化された NVIDIA SDK Manager。Jetson Orin シリーズデバイス（AGX Orin、Orin NX、Orin Nano）のフラッシュとプロビジョニング用。CLI と GUI の 2 つの variant を提供。`ubuntu:${BASE_IMAGE}` をベースに、公開 CUDA apt リポジトリから SDK Manager をインストール。[`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 上に構築。

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## TL;DR

```bash
make build && make run -- -t cli
```

## 前提条件

- **Host OS**：x86_64 Linux
- **Docker Engine** >= v20.10.6
- **Host パッケージ**（x86 ホストから ARM ターゲットをフラッシュする場合に必須）：

  ```bash
  sudo apt-get install qemu-user-static binfmt-support
  sudo update-binfmts --enable
  ```

- **Jetson デバイス**をリカバリモードにする（フラッシュ時）

## クイックスタート

```bash
make build -- -t cli             # CLI イメージをビルド
make run -- -t cli               # SDK Manager CLI を実行
```

## Ubuntu バージョンの切り替え

デフォルトは `ubuntu:24.04`。`22.04` に切り替え：

```bash
make setup -- set build.arg_4 BASE_IMAGE=ubuntu:22.04
make build -- -t cli
```

## 使い方

```bash
make build -- -t cli             # CLI variant をビルド
make build -- -t gui             # GUI variant をビルド（X11）
make run -- -t cli               # CLI インタラクティブモード
make run -- -t gui               # GUI モード
make exec                        # 実行中のコンテナに入る
make stop                        # コンテナを停止
```

### サポートされる Jetson ターゲット

| Target パラメータ | デバイス |
|------------------|---------|
| `JETSON_AGX_ORIN_TARGETS` | Jetson AGX Orin |
| `JETSON_ORIN_NX_TARGETS` | Jetson Orin NX |
| `JETSON_ORIN_NANO_TARGETS` | Jetson Orin Nano |

## 永続化データ

SDK Manager のダウンロードファイルとログインセッションは `.data/` に永続化（gitignore 済み）：

| Host パス | コンテナパス | 用途 |
|-----------|------------|------|
| `.data/nvsdkm/` | `${HOME}/.nvsdkm` | ログインセッションキャッシュ |
| `.data/downloads/` | `${HOME}/Downloads/nvidia/sdkm_downloads` | SDK コンポーネントダウンロード（~10-20 GB） |

## Smoke Tests

```bash
make build test
```

詳細は [TEST.md](test/TEST.md) を参照。
