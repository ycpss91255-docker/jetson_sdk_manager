# Jetson Orin ファクトリーフラッシュコンテナ

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

コンテナ化された NVIDIA Jetson Linux（L4T）ファクトリーフラッシュワークフロー。Jetson Orin シリーズ（AGX Orin、Orin NX、Orin Nano）に対応。公式 BSP archive の `l4t_initrd_flash.sh --no-flash` / `--flash-only` を再現可能な 2 つの Docker stage にラップ。[`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) 上に構築。

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## 目次

- [TL;DR](#tldr)
- [なぜ SDK Manager ではなくファクトリーフラッシュか](#なぜ-sdk-manager-ではなくファクトリーフラッシュか)
- [前提条件](#前提条件)
- [`jetson.yaml` の設定](#jetsonyaml-の設定)
- [クイックスタート](#クイックスタート)
- [Stages](#stages)
- [Clean コマンド](#clean-コマンド)
- [Inspector（SDK Manager GUI）](#inspectorsdk-manager-gui)
- [永続データ](#永続データ)
- [アーキテクチャ](#アーキテクチャ)
- [Smoke Tests](#smoke-tests)
- [ディレクトリ構成](#ディレクトリ構成)
- [トラブルシューティング](#トラブルシューティング)

---

## TL;DR

```bash
./script/host_setup.sh                                # boot ごとに 1 回:qemu + nfsd + USB 調整(host 上で実行)
./script/init_data_dirs.sh                            # 初回のみ：data/ マウント点を非 root の自分で先に作成
ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml   # preset を 1 つ選ぶ

make run -- -t prepare    # フェーズ 1：BSP ダウンロード + フラッシュイメージ生成（約 30 分）
# Jetson を APX recovery に入れる（REC を押しながら RESET をタップ）
make run -- -t flash      # フェーズ 2：Jetson に書き込み（約 10 分）

# ...または Jetson を APX recovery に入れた状態で、1 コマンドで両フェーズを実行:
make run -- -t prepare && make run -- -t flash
```

> `./script/host_setup.sh` は boot ごとの host 前提を一括実行します(見 [前提条件](#前提条件));`make run` は初回に不足している stage image を自動 build します。解説付きの完全な手順——各 stage の `make build`、初回起動後の `nvidia-jetpack` インストール、headless 接続、中断後の再開——は [クイックスタート](#クイックスタート) を参照。

## なぜ SDK Manager ではなくファクトリーフラッシュか

NVIDIA SDK Manager の GUI / `--cli` フローは、host 上で NFS server を動かし、rootfs を USB device-mode 経由でデバイスへエクスポートし、`iptables` で host のネットワークスタックをブリッジしてフラッシュします。Docker 内（`--privileged --network host` を付けても）この組み合わせは信頼性のある動作になりません：NFS server のバインドが不安定、コンテナ内の `iptables` ルールが host の nftables に届かないことがある、`usb-gadget` device-mode forwarding が失敗する。典型的な症状が、NVIDIA 公式 Docker image でも起きる [Flashing - 99% で停止](https://forums.developer.nvidia.com/t/docker-sdk-manager-flash-nx-struck-at-99/365066) です。

本 repo はこの経路を完全に回避します：**prepare** stage は BSP 同梱の `l4t_initrd_flash.sh --no-flash` で host 側にフラッシュイメージを生成（Jetson 不要、NFS 不要、`iptables` 不要）；**flash** stage は `--flash-only` で書き込みます：Jetson は `tegrarcm_v2` USB 接続で最小限の initrd を起動し、その同じリンク上のローカル NFS エクスポートから image を取得します。このエクスポートには host の `nfsd` カーネルモジュールが必要ですが（[前提条件](#前提条件) 参照）、SDK Manager と違って `iptables` 操作も `usb-gadget` device-mode forwarding も**不要**なので、privileged コンテナ内で安定して動作します。

SDK Manager は **`inspector`** stage にカタログブラウザとして残しています。JetPack 各リリースにどの `.deb` パッケージが含まれるかを調べる用途です。その Install ボタンは Docker 内で依然として機能しません；entrypoint がその旨の banner を表示します。

## 前提条件

- **Host OS**：x86_64 Linux。
- **Docker Engine** >= v20.10.6。
- **repo を置く host のファイルシステムは ext4 / xfs / btrfs であること。** `apply_binaries.sh` は rootfs ツリーに setuid バイナリ（`sudo`）と root 所有のファイルを生成します。NTFS / exFAT / `fuseblk` / FAT は展開時に setuid と ownership を黙って落とすため、フラッシュ後の Jetson は起動後に `sudo` が起動を拒否します。`prepare.sh` は非 unix FS を検出するとアクションメッセージ付きで中止します；repo を ext4 / xfs / btrfs パーティションに移すか、ext4 ディレクトリを `./data/jetson_l4t/` に bind-mount してください。
- **boot ごとの host セットアップ — `./script/host_setup.sh`。** Jetson を接続する前に host 上で実行。1 コマンドで **QEMU binfmt** を登録（`prepare` で BSP の ARM64 ツールを実行）、**`nfsd`** モジュールをロード（`flash` がローカル NFS エクスポートで payload を Jetson の initrd に渡す —— `iptables` / `usb-gadget` forwarding なし）、**USB オートサスペンド**を無効化、**`usbfs` buffer** を 2048 MB に引き上げ（後の 2 つは `tegrarcm_v2` / NFS の bulk write が途中で止まるのを防止）。これらは再起動でリセットされるため、boot ごとに再実行します。スクリプトが**やらない**こと 2 つ:
  - **`nfsd` の永続化**(次回 boot でロード不要にする):`echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf`。
  - **per-device オートサスペンド上書き**、特定の port がまだデバイスを park する場合(Jetson が APX に入った後 `lsusb -t` でパスを探す):`echo on | sudo tee /sys/bus/usb/devices/<bus>-<port>/power/control`。

  スキップ時の症状:QEMU なし → `prepare` で `chroot: ... Exec format error`;`nfsd` なし → `flash` で `RPC: Program not registered` / `Return value 114`。`prepare` は QEMU のステップだけが必要です。
- **Jetson が APX recovery に入っていること**（`flash` stage のみ；`prepare` は Jetson 接続不要）。

## `jetson.yaml` の設定

トップレベルの `jetson.yaml` は `config/jetson/` 配下の preset への symlink です。ボード + ストレージターゲットに合うものを 1 つ選びます：

| Preset | ボード | ストレージ |
|---|---|---|
| `agx-orin-emmc.yaml` | AGX Orin devkit | eMMC (`mmcblk0p1`) |
| `agx-orin-nvme.yaml` | AGX Orin devkit | NVMe (`nvme0n1p1`) |
| `agx-orin-usb.yaml` | AGX Orin devkit | USB SSD (`sda1`) |
| `orin-nx-nvme.yaml` | Orin NX devkit-super | NVMe |
| `orin-nano-nvme.yaml` | Orin Nano devkit-super | NVMe |
| `orin-nano-sd.yaml` | Orin Nano devkit-super | microSD（USB リーダー経由） |

preset の切り替えは symlink を張り直すだけ：

```bash
ln -sf config/jetson/orin-nx-nvme.yaml jetson.yaml
```

各 preset が設定する項目：

- `jetpack.version` — `config/jetson/_l4t_mapping.yaml` 経由で L4T release バージョン + BSP / rootfs ダウンロード URL に解決されます。
- `hardware.board` — alias が NVIDIA の `--target` 名にマップされます。
- `storage.device` — alias が storage mode（eMMC は `internal`、NVMe / USB / SD は `external`）と、external mode で Jetson recovery initrd が見るデフォルトの kernel device パスにマップされます。
- `user.{username,password,hostname,autologin}` — `l4t_create_default_user.sh` でデフォルト user を事前作成し、初回起動の OEM-config をスキップします。
- `network`（任意）— デフォルトは DHCP；`method: static` を設定すると rootfs に `NetworkManager` system-connection profile をインストールします。

**マルチスロット USB リーダー / 非デフォルトの device 番号。** USB SSD や microSD リーダーが非デフォルトの LUN に出る場合（典型的には空スロットが `sda` として enumerate され、カードが `sdb` に来る）、`storage.device_path` を追加して alias 解決の kernel device を上書きします：

```yaml
storage:
  device: usb
  device_path: sdb1      # usb alias デフォルトの sda1 を上書き
```

正しい device_path の見つけ方：先にストレージを host に接続して `lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN` を実行。Jetson recovery initrd の enumeration は多くの場合 host と一致します。初回フラッシュが `Error opening /dev/sd*: No medium found` で中止する場合は、次の文字を試します（`sdb1` → `sdc1`）— [トラブルシューティング](#error-error-opening-devsda-no-medium-foundmicrosd-usb-リーダー経由) 参照。`device_path` を `storage.device: emmc`（internal mode）と同時に設定すると、検証段階で拒否されます。

完全なスキーマとコメントは `config/jetson/_example.yaml` を参照。

**JetPack バージョンを追加するには**：`config/jetson/_l4t_mapping.yaml` を編集し、`jetpack_to_l4t` の下に項目を追加（[Jetson Linux Archive](https://developer.nvidia.com/embedded/jetson-linux-archive) から `l4t_release` と `bsp_url` / `rootfs_url` を取得）して、prepare / flash image を再 build します。

## クイックスタート

> **`make run` の前に：** boot ごとに `./script/host_setup.sh` を 1 回実行（QEMU binfmt、`nfsd`、USB 調整 —— [前提条件](#前提条件) 参照）、初回は `./script/init_data_dirs.sh` も実行（さもないと Docker daemon が `data/` マウント点を root で作成し、コンテナ内の非 root ユーザーがアクセスできなくなります）。

```bash
./script/host_setup.sh      # boot ごとに 1 回:QEMU binfmt + nfsd + USB 調整(host 上で実行)
./script/init_data_dirs.sh  # 初回のみ
ln -sf config/jetson/agx-orin-emmc.yaml jetson.yaml

# フェーズ 1 — host 側でイメージ生成（Jetson 接続不要）
make build -- -t prepare
make run -- -t prepare

# フェーズ 2 — Jetson へ書き込み
# Jetson を APX recovery に：電源オフ、REC を押しながら、電源を再接続、離す。
make build -- -t probe   # 一度に build できる stage は 1 つ（最後の -t が有効）、分けて build
make build -- -t flash
make run -- -t probe     # Jetson が APX にあるか確認 (exit 0 = ready to flash)
make run -- -t flash
```

Jetson が新しくフラッシュした OS で起動したら、NVIDIA の OTA apt repository から残りの JetPack コンポーネントをインストール：

```bash
sudo apt update
sudo apt install -y nvidia-jetpack
```

CUDA、cuDNN、TensorRT、VPI、マルチメディア API、container runtime などをインストールします。SDK Manager が push するコンポーネント集合と同じで、Jetson が自分で取得するだけの違いです。

### 初回接続（USB、ネットワーク設定不要）

フラッシュした L4T rootfs には NVIDIA の USB device-mode サービスが含まれるため、Jetson はフラッシュに使ったのと同じ USB-C ケーブル上で固定の **`192.168.55.1`** に到達できます。`jetson.yaml` の `network:` 設定は**不要**です：

```bash
ssh <username>@192.168.55.1     # ユーザー名 / パスワードは jetson.yaml の user.* ブロックから
```

host 側は USB ネットワークインターフェースに `192.168.55.x` を自動設定します（`ip a` で確認）。このリンクは任意の [`network:`](#jetsonyaml-の設定) ブロック（Jetson のイーサネット / Wi-Fi を NetworkManager で設定）とは独立しており、両立します。`192.168.55.1` は L4T に固定で組み込まれており、本 repo からは変更できません。

### 中断後の再開

各フェーズは進捗を `data/jetson_l4t/.../.prepared.yaml` に記録します。`make run -- -t prepare` を再実行すると完了済みステップ（BSP ダウンロード、rootfs 展開、`apply_binaries.sh`、user 作成、image 生成）をスキップします。JetPack / board の変更は mismatch として検出され、`./script/clean.sh l4t` を示すアクションメッセージ付きで中止します。

## Stages

| Stage | 用途 | Jetson 接続必要 |
|---|---|---|
| `devel` | フラッシュツール（`l4t_initrd_flash.sh` の依存）。`make build` のデフォルト target。 | いいえ |
| `devel-test` | Lint（`shellcheck` + `hadolint`）+ bats smoke tests。CI のみ。 | いいえ |
| `prepare` | フェーズ 1 — BSP + sample rootfs ダウンロード、`apply_binaries.sh`、`l4t_create_default_user.sh`、`l4t_initrd_flash --no-flash`。 | いいえ |
| `flash` | フェーズ 2 — `l4t_initrd_flash --flash-only`。 | **はい**、APX recovery |
| `probe` | 診断。USB をスキャンして NVIDIA vendor `0955` を探し、各デバイスが recovery 範囲にあるか注記し、APX の Jetson が無ければ exit 非 0。flash 前に接続確認のため実行でき、フラッシュ全体を走らせる必要がありません。 | 推奨 |
| `inspector` | SDK Manager GUI、JetPack コンポーネントカタログの閲覧用。Install ボタンは Docker 内で機能しません — [Inspector](#inspectorsdk-manager-gui) 参照。 | いいえ |
| `inspector-test` | `sdkmanager --ver` の sanity check。CI のみ。 | いいえ |

## Clean コマンド

`script/clean.sh` は使い捨ての `alpine:3` コンテナ経由で `./data/jetson_l4t/` を操作するため、host 側のツールは不要です。

| コマンド | 効果 |
|---|---|
| `./script/clean.sh build` | 生成されたフラッシュイメージのみ削除（`tools/kernel_flash/images/`）。 |
| `./script/clean.sh rootfs` | `rootfs/` のみ削除、BSP とダウンロード済み tarball は保持。 |
| `./script/clean.sh l4t` | `Linux_for_Tegra/` ツリー全体を削除（BSP + rootfs + image）。tarball は保持。 |
| `./script/clean.sh all` | l4t + `data/downloads/` の tarball も削除。 |

`prepare.sh` が JetPack バージョンの mismatch を報告したら、`./script/clean.sh l4t` でリセットします。

## Inspector（SDK Manager GUI）

`inspector` stage は NVIDIA SDK Manager を含みますが、用途は**カタログブラウザ**でありフラッシュツールではありません。JetPack 各バージョンにどの `.deb` パッケージが含まれるか調べたり、`apt install nvidia-jetpack` を実行せずに個別の `.deb` をダウンロードしたりできます。

```bash
make build -- -t inspector
make run -- -t inspector
```

entrypoint は Install ボタンが Docker 内でなぜ機能しないかの banner を表示し、対話モードでは GUI 起動前に Enter 待ちします。`sdkmanager-gui` へ引数を渡す場合は `make run` の位置引数で渡します。

GUI モードは host の X11 セッションが必要です；base template が `$DISPLAY` を自動検出し、X11 socket と `XAUTHORITY` を転送します。

## 永続データ

`./data/` 配下の各パスがコンテナに bind-mount されます（gitignored）。

| Host パス | コンテナパス | 用途 |
|---|---|---|
| `./data/jetson_l4t/` | `/srv/jetson_l4t` | BSP + rootfs + 生成されたフラッシュイメージ（ファクトリーフラッシュ）。**ext4 / xfs / btrfs であること。** |
| `./data/downloads/` | `${HOME}/Downloads/nvidia/sdkm_downloads` | キャッシュした tarball（BSP + sample rootfs）、SDK Manager と共用。 |
| `./data/nvsdkm/` | `${HOME}/.nvsdkm` | SDK Manager ログインセッションキャッシュ。inspector stage のみ。 |
| `./data/nvidia_sdk/` | `${HOME}/nvidia/nvidia_sdk` | SDK Manager 管理の SDK インストールフォルダ。inspector stage のみ。 |
| `./jetson.yaml` | `/etc/jetson.yaml`（読み取り専用） | ユーザー設定、`prepare.sh` / `flash.sh` / `inspector-entrypoint.sh` が読み取り。 |

## アーキテクチャ

```mermaid
graph TD
    EXT1["test-tools image\nbats + shellcheck + hadolint"]
    EXT2["ubuntu:${BASE_IMAGE}\n(22.04 / 24.04)"]
    EXT3["NVIDIA Jetson Linux Archive\nBSP + sample rootfs tarballs"]
    EXT4["CUDA apt repo\ncuda-keyring + sdkmanager"]

    EXT2 --> sys["sys\nuser/group, locale, timezone"]
    sys --> devel-base["devel-base\ndev tools (git, vim, tmux, curl, wget)"]
    devel-base --> devel["devel\nflash tooling + yq binary"]

    devel --> prepare["prepare\nCMD prepare.sh\n(host-side image build)"]
    EXT3 --> prepare
    devel --> flash["flash\nCMD flash.sh\n(USB write to Jetson)"]
    devel --> probe["probe\nCMD probe.sh\n(lsusb 0955 sanity check)"]
    devel --> inspector["inspector\n+ SDK Manager + X11 libs\nCMD inspector-entrypoint.sh"]
    EXT4 --> inspector

    EXT1 --> devel-test["devel-test (ephemeral)\nshellcheck + hadolint + bats"]
    devel --> devel-test
    inspector --> inspector-test["inspector-test (ephemeral)\nsdkmanager --ver"]
```

## Smoke Tests

詳細は [TEST.md](test/TEST.md) を参照。

```bash
make build test
```

`devel-test` stage は `devel` image に対して bats テストを実行します；2 つの `sdkmanager` アサーションはここでは skip されます（`inspector` image 内で bats を再実行したときのみ実行）。

## ディレクトリ構成

```text
jetson_sdk_manager/
├── jetson.yaml -> config/jetson/agx-orin-emmc.yaml   # symlink；preset 切り替え
├── compose.yaml                 # Docker Compose（派生、gitignored）
├── Dockerfile                   # sys → devel-base → devel → {prepare, flash, inspector}
├── Makefile -> .base/script/docker/Makefile
├── .base/                       # 共有テンプレート（git subtree）
├── data/                        # 永続状態（gitignored）
│   ├── jetson_l4t/              #   BSP + rootfs + フラッシュイメージ
│   ├── downloads/               #   BSP / rootfs tarball
│   ├── nvsdkm/                  #   SDK Manager ログインセッション（inspector）
│   └── nvidia_sdk/              #   SDK Manager インストールフォルダ（inspector）
├── config/
│   ├── docker/setup.conf        # ランタイム設定 — source of truth
│   ├── jetson/                  # フラッシュ preset と schema
│   │   ├── _example.yaml        #   コメント付き canonical schema
│   │   ├── _l4t_mapping.yaml    #   JetPack → L4T release / URL（build-time）
│   │   └── *.yaml               #   board / storage ごとの preset
│   └── packages/                # inspector の X11 lib リスト（Ubuntu codename ごと）
├── doc/
│   ├── adr/                     # アーキテクチャ決定記録
│   ├── changelog/CHANGELOG.md
│   ├── test/TEST.md
│   ├── Flash_Workflow.md        # prepare/flash フェーズの詳細解説
│   ├── README.zh-TW.md
│   ├── README.zh-CN.md
│   └── README.ja.md
├── script/
│   ├── prepare.sh               # フェーズ 1 entrypoint
│   ├── flash.sh                 # フェーズ 2 entrypoint
│   ├── clean.sh                 # Volume クリーンアップコマンド
│   ├── inspector-entrypoint.sh  # SDK Manager GUI ランチャー + 警告 banner
│   ├── lib/                     # yaml / download / volume / errors helpers
│   ├── host_setup.sh            # 一括 per-boot host 前提(qemu/nfsd/USB)
│   ├── init_data_dirs.sh        # 初回に非 root で data/ を作成
│   ├── entrypoint.sh            # コンテナ entrypoint（logging tee）
│   ├── build.sh -> ../.base/script/docker/wrapper/build.sh
│   ├── run.sh   -> ../.base/script/docker/wrapper/run.sh
│   ├── exec.sh  -> ../.base/script/docker/wrapper/exec.sh
│   ├── stop.sh  -> ../.base/script/docker/wrapper/stop.sh
│   ├── setup.sh -> ../.base/script/docker/wrapper/setup.sh
│   ├── setup_tui.sh -> ../.base/script/docker/wrapper/setup_tui.sh
│   └── prune.sh -> ../.base/script/docker/wrapper/prune.sh
├── test/smoke/orin_install_env.bats
├── .github/workflows/main.yaml
└── .gitignore
```

## トラブルシューティング

### `prepare.sh` 中止：「L4T_ROOT ... is on ntfs/exfat/fuseblk」

`apply_binaries.sh` は setuid バイナリ（`sudo`）と root 所有のファイルを生成します。NTFS / exFAT / `fuseblk` / FAT はこの両方を黙って落とすため、生成された Jetson は起動後に `sudo` が起動を拒否します。repo を ext4 / xfs / btrfs パーティションに移すか、ext4 ディレクトリを `./data/jetson_l4t/` に bind-mount してください：

```bash
sudo mkdir -p /var/lib/jetson_l4t
sudo mount --bind /var/lib/jetson_l4t ./data/jetson_l4t
```

bind-mount のターゲットはシステムディスク上である必要はありません — ext4 / xfs / btrfs パーティション内のディレクトリならどこでもよく、2 台目の SSD やマウント済みのデータドライブも可。空き容量が十分なもの（1 回の完全な prepare で約 15 GB）を選びます：

```bash
sudo mkdir -p /media/<ext4-mount>/jetson_l4t
sudo mount --bind /media/<ext4-mount>/jetson_l4t ./data/jetson_l4t
```

どちらの bind mount も永続しません；再起動後 `make run -- -t prepare` の前に再 mount してください。

診断目的のみ、`JETSON_ALLOW_NON_UNIX_FS=1` で abort を警告に降格できます：

```bash
JETSON_ALLOW_NON_UNIX_FS=1 make run -- -t prepare
```

**この flag は非 unix ファイルシステムでは使えるフラッシュを生成できません**。NVIDIA の `apply_binaries.sh` 自体が `find rootfs/etc/passwd -user root -group root` で rootfs の ownership を確認し、sample rootfs が誤った owner で展開されると 7/10 ステップ目で自ら abort します。この escape hatch は、maintainer がそのステップまで走らせて失敗モードを実証するためだけのもので、filesystem 制約を回避する手段ではありません。

### `prepare.sh` 中止：volume mismatch

`.prepared.yaml` marker が示す volume は別の JetPack / board 用に準備されており、現在の `jetson.yaml` の選択と異なります。クリアして再実行：

```bash
./script/clean.sh l4t
make run -- -t prepare
```

### `chroot: failed to run command 'dpkg': Exec format error`

host kernel が ARM64 バイナリを実行できません。QEMU binfmt interpreter を登録：

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

boot ごとに 1 回実行。

### `Could not detect a board` / Jetson が recovery に入っていない

`flash.sh` は `lsusb` に NVIDIA VID `0955` + recovery PID（`7023` / `7223` / `7423` / `7523` / `7e19`）が出るか確認し、無ければ中止します。`probe` stage を単独で実行すると同じ確認ができます — 別のケーブル / port を試すときに毎回フラッシュ全体を走らせる必要がありません：

```bash
make run -- -t probe
```

bus 上の全 NVIDIA-vendor デバイスを列挙し、どれが recovery 範囲かを注記し、少なくとも 1 つが recovery のときのみ exit 0 になります。

recovery モードへの入り方：

1. 電源を切る。
2. USB-C ケーブルで Jetson の**フロントパネル**（ボタン側）と host を接続。
3. **REC**（中央のボタン）を押し続ける。
4. 電源を接続（または Power を押す）。
5. 約 2 秒後に REC を離す。

host で確認：

```bash
lsusb | grep -i 'NVIDIA Corp'
```

| 出力 | 状態 |
|---|---|
| `0955:7023` / `7223` / `7423` / `7523` / `7e19` NVIDIA Corp. APX | Jetson が recovery（flash 開始可能） |
| `0955:<その他 PID>` | OS で起動済み — recovery に入り直す |
| （出力なし） | 未検出 — ケーブル / port を変える / 直結（hub を使わない） |

recovery モードは USB 2.0（480 Mbps）で動作します。これは正常です — APX モードでは USB 3 コントローラは無効です。

### `clnt_create: RPC: Program not registered` / `NFS server is not running` / `Error 114`

`flash` 段階の `l4t_initrd_flash.sh` はローカル NFS エクスポートで Jetson の initrd に payload を渡しますが、コンテナは host とカーネルを共有しており、host が `nfsd` モジュールをロードしていません:

```
 * Not starting NFS kernel daemon: no support in current kernel.
clnt_create: RPC: Program not registered
NFS server is not running
make: *** [Makefile:41: run] Error 114
```

host 側で（コンテナ内ではなく）ロードしてから flash を再実行：

```bash
sudo modprobe nfsd
make run -- -t flash
```

`echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf` で再起動後も有効にできます。[前提条件](#前提条件) 参照。`flash.sh` は現在これを事前チェックし、同じ案内付きで早期に中止します。

### `ERROR: might be timeout in USB write` / `Return value 3`

Boot ROM 通信が USB bulk transfer 中に停止：

```
Sending bct_br
ERROR: might be timeout in USB write.
Error: Return value 3
```

前回の中断したフラッシュが残した USB endpoint の状態です。**ハードウェア** power-cycle で APX recovery に入り直す必要があります——電源オフ、REC を押し続ける、電源を再接続、離す(`tegrarcm_v2 --reboot recovery` では不十分)。

あわせて、この boot で `./script/host_setup.sh` を実行したか確認してください——USB buffer を引き上げ、オートサスペンドを無効化します([前提条件](#前提条件) 参照)。

### `Error: Error opening /dev/sda: No medium found`（microSD USB リーダー経由）

マルチスロットのコンボリーダーは各スロットを別々の LUN として出し、`usb` alias はデフォルトで `sda1` にマップされます。空スロットが `sda` として enumerate され、カードが `sdb` に来る場合、フラッシュはカードに触れる前に中止します：

```bash
$ lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN
sda    0B  Generic-  SD/MMC          usb     # 空スロット
sdb  117.8G Generic-  Micro SD/M2    usb     # カードはここ
```

**正しい `device_path` の見つけ方**（host の enumeration は多くの場合 Jetson recovery initrd と一致しますが、保証はされません）：

1. フラッシュ時と同じ USB 構成でストレージを host に接続。
2. `lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN` を実行；`SIZE` がカード / SSD に一致するものがターゲット device。
3. `jetson.yaml` に `storage.device_path: <name>1`（例 `sdb1`）を設定 — パーティション `1` が `l4t_initrd_flash.sh` の想定です。

初回試行が同じように失敗する場合、Jetson initrd の bus enumeration が host と異なります；次の文字を試します（`sdb1` → `sdc1`）。完全な上書きセマンティクスは [`jetson.yaml` の設定](#jetsonyaml-の設定) 参照。

その他の回避策（おおよその推奨順）：

1. シングルスロットの microSD リーダーを使う — 常に `sda` として enumerate され、alias デフォルトに合致。
2. カードを `/dev/sda` にマップされるスロットへ移す（必要なら microSD-to-SD アダプタを使用）。

### APP partition でフラッシュが停止（external storage）

USB ethernet 経由の大容量連続転送は、APP partition 展開ステップで止まることがあり、約 12 分の timeout 後に失敗します。選択肢：

1. **eMMC** にフラッシュ（`storage.device: emmc`）し、Jetson 上で `sudo apt install nvidia-jetpack`。
2. **NVMe SSD** を使う — PCIe 直結は USB-ethernet 展開より高速。
3. Jetson を完全に power-cycle してから再試行。
