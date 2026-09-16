# Jetson Orin 工廠燒錄容器

[![CI](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/jetson_sdk_manager/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

用**三條指令**從任何 x86_64 Linux 電腦燒錄 **Jetson Orin**(AGX Orin、Orin NX、Orin Nano)。NVIDIA 的 `l4t_initrd_flash.sh` 跑在 Docker 裡,host 只需要 Docker——不用 SDK Manager、不用 NVIDIA 帳號。基於 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)。

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

| JetPack | L4T | 狀態 |
|---|---|---|
| **6.2.2** | R36.5.0(`r36_release_v5.0`) | 目前唯一接好的版本——[新增其他版本](#設定-jetsonyaml) |

---

- [快速開始](#快速開始)
- [進入 recovery(REC)模式](#進入-recoveryrec模式)
- [燒錄之後](#燒錄之後)
- [前置需求](#前置需求)
- [設定 `jetson.yaml`](#設定-jetsonyaml)
- [資料、清理、移除 repo](#資料清理移除-repo)
- [疑難排解](#疑難排解)
- [深入了解](#深入了解)

## 快速開始

```bash
git clone https://github.com/ycpss91255-docker/jetson_sdk_manager.git   # 要用 git clone,不要「Download ZIP」(zip 缺 .base/ subtree)
cd jetson_sdk_manager

./jetson status      # 哪些就緒、哪些沒有——把 ✘ 的先處理掉
#   → 先讓 Jetson 進 recovery:見下一節(prepare 的最後一步要透過 USB 讀板子的 ID)
./jetson prepare     # host 設定(問一次 sudo)+ 下載 BSP + 產生燒錄映像。約 30 分
./jetson flash       # 透過 USB 寫入。約 10 分
```

`./jetson all` 會先等板子出現在 recovery,再連跑 prepare 與 flash。`./jetson` 做的每一件事都是普通的 script 或 `make` target——見[深入了解](#深入了解)。

需要什麼:x86_64 Linux host + Docker(不用 `sudo` 就能跑)、一條 USB-C 線、約 20 GB 空間、第一次約 40 分鐘(之後會略過下載與已完成步驟)。整個過程板子都要在 recovery:prepare 最後一步會從板子 EEPROM 讀 board spec(ID / SKU / revision),flash 則寫入它。repo 放在 NTFS / exFAT 上也可以——`prepare` 會處理([怎麼做](#前置需求))。

## 進入 recovery(REC)模式

Jetson 的 Boot ROM 只在 **Force Recovery**(「REC」/「APX」/「RCM」都是同一件事)狀態下接受燒錄。用 devkit 上的按鍵進入;之後 host 看到的會是 USB 裝置 `0955:7023` 之類,而不是已開機的 OS。

**AGX Orin Developer Kit** — 三顆按鍵(Power、Force Recovery、Reset)在前緣下方,支援 **device / recovery mode** 的 USB-C 孔就是緊鄰按鍵的那個(另一個較遠的 USB-C 支援 DisplayPort,**不能**拿來燒錄)。示意圖——實際照片與接頭編號請看下方連結的 NVIDIA user guide:

```
  AGX Orin devkit 前緣(示意,非實際比例)

   ┌──────────┐    ┌─────┐  ┌─────┐  ┌─────┐
   │  USB-C   │    │ PWR │  │ REC │  │ RST │
   └──────────┘    └─────┘  └─────┘  └─────┘
     ▲ 燒錄 /        電源     force    reset
       device-mode            recovery
       孔
```

1. 拔掉電源。
2. USB-C 線從 **device-mode 的 USB-C 孔(按鍵旁邊)** 接到 host。直接接,不要經 hub。若 `./jetson status` 一直看不到板子,先換另一個 USB-C 孔試試。
3. **按住 REC**(中間那顆)。
4. 接回電源(或按住 REC 的同時按 PWR)。
5. 約 2 秒後放開 REC。

板子已經通電時的替代做法:按住 **REC**,點一下 **RST**,約 2 秒後放開 REC。

**Orin NX / Orin Nano Developer Kit** — 載板沒有按鍵。用跳線把 12-pin 按鍵排針(J14)上的 **`FC REC`** 與 **`GND`** 短路,接上電源(或點一下 `RST`),再拔掉跳線。pin 名稱印在載板上;官方 user guide 有照片。

在 host 確認:

```bash
./jetson status          # 最後一行:「Jetson in recovery: … 0955:7023 NVIDIA Corp. APX」
./jetson wait-rec        # 或:印出上面步驟,等到板子出現為止
```

| host 看到的 USB ID | 意思 |
|---|---|
| `0955:7023`(AGX Orin)· `7223` · `7423` · `7523` · `7e19` — `NVIDIA Corp. APX` | 在 recovery——可以燒(PID 對應模組 SKU;`flash` 接受的清單在 `script/lib/usb.sh`)|
| `0955:7020 … L4T (Linux for Tegra) running on Tegra` | 已開機進 OS——重做一次 |
| 沒有 | 沒偵測到——換線 / 換孔 / 不經 hub;確認線接在按鍵旁邊那個孔 |

Recovery 走 USB 2.0,是正常的。板子會一直停在 recovery 直到斷電,所以在 `./jetson prepare` 前進一次就放著。若某一步以 `ERROR: might be timeout in USB write` 結束,是 Boot ROM 的 USB endpoint 被上次中斷的嘗試卡住——重新上電進 recovery 再跑一次(prepare 會從停下的地方續跑)。官方照片與完整按鍵說明見 NVIDIA [Jetson AGX Orin Developer Kit User Guide](https://developer.nvidia.com/embedded/learn/jetson-agx-orin-devkit-user-guide/index.html) 與 [Jetson Linux Quick Start](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/IN/QuickStart.html)(「To Flash the Jetson Developer Kit Operating Software」—「force recovery mode」)。

## 燒錄之後

Jetson 會重開進剛燒好的 OS。**用同一條 USB-C 線**就能連到固定位址(NVIDIA 的 USB device-mode,不用設定):

```bash
ssh jetson@192.168.55.1          # 帳號 / 密碼來自 jetson.yaml(預設 jetson / jetson)
passwd                           # 馬上改掉預設密碼——它是公開的
sudo apt update && sudo apt install -y nvidia-jetpack     # CUDA、cuDNN、TensorRT、VPI…(SDK Manager 會裝的那些)
```

host 端的 USB 網卡會自動拿到 `192.168.55.x`(`./jetson flash` 在板子開機那一刻把 NetworkManager 還回去)。乙太 / Wi-Fi 預設 DHCP;想固定 IP 可在 `jetson.yaml` 的 `network:` 區塊設定。

host 用完了?`./jetson teardown` 在同一次開機內還原 kernel / mount 的變更(重開機效果相同)。

## 前置需求

- **x86_64 Linux** host(燒錄階段不支援 WSL、macOS 上的 VM)、**Docker ≥ 20.10** 且不用 `sudo`(`docker run --rm hello-world`;不行就 `sudo usermod -aG docker "$USER"` 後重新登入)、`make`、`lsusb`。
- **約 20 GB 可用空間**放 BSP、rootfs 與產生的映像;其中約 4 GB 是一次性下載。
- **`./data/jetson_l4t/` 必須是 ext4 / xfs / btrfs**——`apply_binaries.sh` 會寫 setuid 與 root 擁有的檔案,NTFS / exFAT / FAT 會靜默丟掉,燒出來的 Jetson `sudo` 會壞。你不必搬 repo:在這類 checkout 上 `./jetson prepare`(透過 `host_setup.sh`)會在 **repo 內**建一個 sparse ext4 映像檔(`data/jetson_l4t.img`,邏輯大小 `L4T_STORE_SIZE=40G`)並 loop-mount 到 `data/jetson_l4t/`。需要 `e2fsprogs` + `util-linux`(`mkfs.ext4`、`losetup`)。想改用另一顆 ext4 碟上的目錄?`L4T_STORE_DIR=/path/on/ext4 ./jetson prepare`。loop 路徑比原生 ext4 慢,主要在 rootfs 解壓時。
- **每次開機**:`./jetson prepare` 會重跑 `host_setup.sh`(QEMU binfmt、`nfsd`、USB autosuspend / buffer、`/srv/jetson_l4t` 橋接、data store 掛載)。重開機後全部歸零;`./jetson status` 會告訴你什麼時候需要再跑。
- **NetworkManager host**(多數桌機/筆電):不擋的話 NM 會在燒到一半時把 USB 連線拆掉。`./jetson flash` 會幫你跑 `nm_flash_guard.sh auto`;只有確定 host 沒跑 NM 才略過。

## 設定 `jetson.yaml`

`jetson.yaml` 是指向 `config/jetson/` 底下某個 preset 的 symlink。預設(`agx-orin-emmc.yaml`)把 AGX Orin devkit(32 GB 與 64 GB 同一個 target)刷到 eMMC。依你的板子 + 儲存目標選一個:

| Preset | 板子 | 儲存 |
|---|---|---|
| `agx-orin-emmc.yaml` | AGX Orin devkit | eMMC (`mmcblk0p1`) |
| `agx-orin-nvme.yaml` | AGX Orin devkit | NVMe (`nvme0n1p1`) |
| `agx-orin-usb.yaml` | AGX Orin devkit | USB SSD (`sda1`) |
| `orin-nx-nvme.yaml` | Orin NX devkit-super | NVMe |
| `orin-nano-nvme.yaml` | Orin Nano devkit-super | NVMe |
| `orin-nano-sd.yaml` | Orin Nano devkit-super | microSD（透過 USB reader） |

切換 preset 重新建立 symlink 即可：

```bash
ln -sf config/jetson/orin-nx-nvme.yaml jetson.yaml
```

每個 preset 設定：

- `jetpack.version` — 透過 `config/jetson/_l4t_mapping.yaml` 解析為 L4T release 版本及 BSP / rootfs 下載 URL。
- `hardware.board` — alias 對應到 NVIDIA `--target` 名稱。
- `storage.device` — alias 對應到 storage mode（eMMC 為 `internal`，NVMe / USB / SD 為 `external`）以及 Jetson recovery initrd 被告知寫入的預設 kernel device 路徑。
- `user.{username,password,hostname,autologin}` — 透過 `l4t_create_default_user.sh` 預先建立預設 user，首次開機跳過 OEM-config。preset 出廠帶有預設的 `jetson` / `jetson` 帳密；**首次登入後請更改密碼**（在裝置上 `passwd`），若板子日後會連上網路，燒錄前請先在這裡設成不同的密碼。
- `network`（選用）— 預設 DHCP；設定 `method: static` 會安裝一份 `NetworkManager` system-connection profile。

**多卡槽 USB reader / 非預設 device 編號。** USB SSD 或 microSD reader 在非預設 LUN 上曝出（典型是空卡槽 enumerate 為 `sda`，卡實際落在 `sdb`）時，加上 `storage.device_path` 覆蓋 alias 解析出的 kernel device：

```yaml
storage:
  device: usb
  device_path: sdb1      # 覆蓋 usb alias 預設的 sda1
```

要找對 device_path 值：先把儲存裝置接上 host，跑 `lsblk -d -o NAME,SIZE,VENDOR,MODEL,TRAN`。Jetson recovery initrd 多數情況下 enumeration 與 host 一致。若第一次燒錄仍以 `Error opening /dev/sd*: No medium found` 中止，換下一個字母（`sdb1` → `sdc1`）— 見 [疑難排解](#error-error-opening-devsda-no-medium-foundmicrosd-透過-usb-reader)。把 `device_path` 與 `storage.device: emmc`（internal mode）同時設定會在驗證階段被拒絕。

完整 schema 與註解見 `config/jetson/_example.yaml`。

**要新增 preset 尚未支援的 JetPack 版本**：編輯 `config/jetson/_l4t_mapping.yaml`，在 `jetpack_to_l4t` 下新增條目（從 [Jetson Linux Archive](https://developer.nvidia.com/embedded/jetson-linux-archive) 取得 `l4t_release` 及 `bsp_url` / `rootfs_url`），然後重建 prepare / flash image。

## 資料、清理、移除 repo

所有東西都在 checkout 底下,gitignored:`data/downloads/`(tarball)、`data/jetson_l4t/`(BSP + rootfs + 映像——NTFS checkout 上是 ext4 映像檔 `data/jetson_l4t.img`)、`data/nvsdkm/` + `data/nvidia_sdk/`(只有 SDK Manager 用)、`log/`。容器把 `data/jetson_l4t/` 看成 `/srv/jetson_l4t`、`jetson.yaml` 看成 `/etc/jetson.yaml`(唯讀)。

每個階段的進度記在 `.prepared.yaml`;重跑 `./jetson prepare` 會略過已完成的。prepare 之後改 JetPack / board 會被偵測為 mismatch,要求先 `./script/clean.sh l4t`。

### Clean 指令

`script/clean.sh` 透過一次性 `alpine:3` 容器操作 `./data/jetson_l4t/`，不需 host 端工具。

| 指令 | 效果 |
|---|---|
| `./script/clean.sh build` | 只移除產生的燒錄 image（`tools/kernel_flash/images/`）。 |
| `./script/clean.sh rootfs` | 只移除 `rootfs/`，保留 BSP 與已下載的 tarball。 |
| `./script/clean.sh l4t` | 移除整個 `Linux_for_Tegra/` 樹（BSP + rootfs + image）。保留 tarball。 |
| `./script/clean.sh all` | l4t + 移除 `data/downloads/` tarball。 |
| `./script/clean.sh purge` | `all` + `host_teardown.sh` + 刪除 L4T data store 本體（repo 內的 `data/jetson_l4t.img`，或 `L4T_STORE_DIR` 目錄）及其 `data/.l4t_store` marker。最強的清除——見 [移除 repo](#移除-repo)。加 `--keep-downloads` 可保留 tarball，下次 prepare 省掉約 3 GB 下載。 |

當 `prepare.sh` 報 JetPack 版本 mismatch 時，執行 `./script/clean.sh l4t` 重置。`purge` 在動手前會先驗證 marker：來自別的 checkout、格式不對、或它不認得的 store 路徑，都會印出診斷並中止，什麼都不刪。

### 移除 repo

這個 repo 產生的東西都在 checkout 底下（`data/`、`log/`、衍生的 `.env` / `compose.yaml`）——host 上只有兩類「開機期」例外：`host_setup.sh` 建立的 mount（NTFS checkout 的 `./data/jetson_l4t`，以及 `/srv/jetson_l4t` NFS 橋接）和 kernel 的 USB / nfsd 設定。重開機就消失，或用 `host_teardown.sh` 立刻還原。所以契約是：

```bash
./jetson purge               # 卸載 + 刪除 store、tarball、marker（加 --keep-downloads 保留 tarball）
cd .. && rm -rf jetson_sdk_manager
```

`purge` 之後 `rm -rf` checkout **零殘留**：沒有 mount、沒有 loop device、沒有 `/srv/jetson_l4t`，`/var/lib` 或家目錄裡也沒有任何東西。CI 的 `store-loop-system` job 會驗證這點（在 runner 上真的 loop mount，然後 `rm -rf` 一個拋棄式 clone）。

**不要**在 `./data/jetson_l4t` 還掛著時 `rm -rf` checkout：`rm` 會穿過 mount 往下刪（store 內容被刪掉——這倒是你要的），然後卡在 mountpoint 本身，留下一個 loop device 綁著已 unlink 的映像檔直到你 `umount`。先跑 `purge`（至少 `host_teardown.sh`）。另外 `/srv/jetson_l4t` 是固定路徑，同一台 host 上不能同時 set up 兩個 checkout。

「全部在 checkout 內」有兩個刻意的例外：Docker image（`make build` 的產物，要清就 `docker rmi`），以及你用 `L4T_STORE_DIR` 明確放在別處的 store。後者 `purge` 會用同一個 alpine 流程清空內容,然後只 `rmdir` 那個空目錄——絕不會對 marker 裡讀到的路徑 `rm -rf`——所以若目錄裡被放了其他東西，purge 會停下並告訴你。

## 疑難排解

`./jetson status` 能診斷出常見的那幾種。每個已知錯誤的原文、原因與解法都在 **[doc/TROUBLESHOOTING.md](TROUBLESHOOTING.md)**(英文):

- `prepare.sh` 中止:*L4T_ROOT … is on ntfs/exfat/fuseblk* · *volume mismatch* · `chroot: … Exec format error`
- *Could not detect a board* / Jetson 不在 recovery
- `RPC: Program not registered` / *NFS server is not running* / `Error 114`(flash 一開始)
- 燒到一半卡住 / 「Flashing – 99 %」/ `mount.nfs: No such file or directory`(NetworkManager)
- `ERROR: might be timeout in USB write` / `Return value 3`
- `Error opening /dev/sda: No medium found`(USB 讀卡機的 microSD)· APP partition 卡住
- SDK Manager:*Device mode forwarding host setup failed* · GUI 元件安裝卡住

## 深入了解

- **[doc/ARCHITECTURE.md](ARCHITECTURE.md)** — 每個 `./jetson` 指令底層跑什麼、`host_setup.sh` 逐步說明、Docker stages、兩條燒錄路徑(工廠燒錄 vs. SDK Manager `cli` / `gui`)、持久化資料、build 圖、目錄結構。
- **[doc/test/TEST.md](test/TEST.md)** — CI 證明了什麼(build、lint、bats、真的 loop-mount lane)、只有硬體能證明什麼(各 preset 驗證狀態:`agx-orin-emmc` 2026-06 實機驗證;其餘僅設定驗證)。
- **[doc/adr/](adr/)** — 架構決策;**[doc/changelog/CHANGELOG.md](changelog/CHANGELOG.md)**。
