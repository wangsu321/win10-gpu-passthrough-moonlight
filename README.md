# R7000P 2020H RTX2060 显卡直通指南（KVM Win10 + Moonlight/Sunshine 串流）

> 联想拯救者 R7000P 2020H (AMD) · RTX 2060 Mobile 直通 Windows 10 虚拟机，宿主机核显显示，
> 通过 Sunshine(虚拟机内) + Moonlight(宿主机) 实现无头串流游戏的完整配置方案。
> 本仓库包含完整配置文档与全部关键配置文件，可直接对照部署。

---

## 1. 项目简介

本方案实现：

- ✅ **显卡直通**：将 NVIDIA RTX 2060 Mobile 完整直通进 KVM Windows 10 虚拟机（含音频/USB/Type-C 附属功能）
- ✅ **防 Code 43**：通过 Hyper-V `vendor_id` 伪装 + 子系统 ID 伪装 + vBIOS ROM 挂载，解决 N 卡驱动报错
- ✅ **无头串流**：虚拟机内运行 Sunshine（NVENC 硬编码），宿主机运行 Moonlight（核显解码），无需显示器直连
- ✅ **一键启动**：`start-win10-moonlight.sh` 自动启动虚拟机并等待系统就绪后自动连接串流

## 2. 硬件配置

| 组件 | 型号 | 说明 |
|------|------|------|
| 主机 | 联想拯救者 R7000P 2020H (AMD版) | 笔记本 |
| CPU | AMD Ryzen 7 4800H | 8核16线程，支持 AMD-V / IOMMU(AMD-Vi) |
| 独显 | NVIDIA GeForce RTX 2060 Mobile | `10de:1f15`，子系统 `17aa:3a47`(Lenovo)，位于 IOMMU Group 9 |
| 核显 | AMD Radeon Graphics (Renoir) | `1002:1636`，宿主机显示输出 |
| 内存 | 14 GB | 虚拟机分配 4 GB |
| 显卡附属 | 01:00.1 音频 / 01:00.2 USB / 01:00.3 UCSI(Type-C) | 全部直通 |
| 外设 | HDMI EDID 欺骗器 | 笔记本 HDMI 直连独显，必须插入以解锁完整分辨率 |

## 3. 软件环境

| 软件 | 版本 | 位置 |
|------|------|------|
| 系统 | Deepin 25 (crimson) | 宿主机 |
| 内核 | 6.6.155-amd64-desktop-hwe | 宿主机 |
| libvirt | 9.10.0 | 宿主机 |
| QEMU | 8.2.0 (pc-q35-8.2) | 宿主机 |
| OVMF | 4M secboot (UEFI + Secure Boot) | 宿主机 |
| Moonlight | 6.1.0 | 宿主机 (`/usr/bin/moonlight`) |
| Windows | Windows 10 (win10.qcow2, 62G) | 虚拟机 |
| Sunshine | 最新版 (Windows 安装包/便携版) | 虚拟机内 |
| virtio-win | virtio-win.iso | 虚拟机驱动 |

## 4. 整体架构

```
┌───────────────────────────── 宿主机 (Deepin 25) ─────────────────────────────┐
│                                                                              │
│   ┌────────────────────── KVM 虚拟机: win10 ──────────────────────┐          │
│   │  Windows 10                                                     │          │
│   │    ├── NVIDIA RTX 2060 (直通, vfio-pci) ── 游戏渲染 + NVENC编码│          │
│   │    ├── Sunshine (抓取独显画面, HEVC/NVENC 编码, 端口 47989)     │          │
│   │    └── virtio 网卡 192.168.122.20 (NAT)                         │          │
│   └────────────────────────────────────────────────────────────────┘          │
│                              │ 串流 (局域网 192.168.122.0/24)                  │
│                              ▼                                                  │
│   Moonlight 6.1.0 ── 解码(核显) ── 显示器                                     │
│   start-win10-moonlight.sh 一键启动+自动连接                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

- 直通使虚拟机独显独占，性能接近原生
- Sunshine 在虚拟机内用 NVENC 编码，宿主机 Moonlight 用核显解码，延迟低、画质高
- 虚拟机通过 NAT 网络 (virbr0, 192.168.122.1) 与宿主机通信

---

## 5. 显卡直通过程

### 5.1 确认 IOMMU 分组

RTX 2060 的 4 个功能位于同一个 IOMMU Group 9，可完整直通：

```bash
# 查看 IOMMU 分组
for g in /sys/kernel/iommu_groups/*; do
  echo "Group $(basename $g): $(ls $g/devices/ 2>/dev/null)"
done
```

实际结果：

```
Group 9:
  0000:01:00.0  VGA compatible controller  NVIDIA TU106M [GeForce RTX 2060 Mobile] (10de:1f15)
  0000:01:00.1  Audio device (10de:10f9)
  0000:01:00.2  USB controller (10de:1ada)
  0000:01:00.3  Serial bus controller / UCSI (10de:1adb)
```

> 💡 4 个设备必须在同一 IOMMU 组才能完整直通；若被拆分需配合 ACS 补丁。

### 5.2 内核参数 (GRUB)

本机实际配置位于 `/etc/default/grub`（见 `config/grub-default.txt`）：

```ini
GRUB_CMDLINE_LINUX_DEFAULT="video=efifb:nobgrt splash quiet loglevel=0 locales=zh_CN.UTF-8"
```

说明：

- `video=efifb:nobgrt`：修复 EFI framebuffer 与直通独显的启动显示冲突
- AMD 平台 **IOMMU 默认开启**（`amd_iommu=on` 为内核默认），无需显式加参数
- 可选优化：追加 `iommu=pt`（直通模式，减少 DMA 开销）。如需修改执行：

```bash
sudo nano /etc/default/grub
sudo update-grub
```

### 5.3 VFIO 驱动绑定

`/etc/modprobe.d/vfio.conf`（见 `config/vfio.conf`）：

```ini
# 将 NVIDIA RTX 2060 Mobile (10de:1f15) 及附属功能绑定到 vfio-pci 用于虚拟机直通
options vfio-pci ids=10de:1f15,10de:10f9,10de:1ada,10de:1adb
softdep nouveau pre: vfio-pci
softdep xhci_hcd pre: vfio-pci
softdep i2c_nvidia_gpu pre: vfio-pci
```

`/etc/modprobe.d/blacklist-nouveau.conf`（见 `config/blacklist-nouveau.conf`）：

```ini
# 禁用 nouveau 和 nvidiafb，防止它们占用 NVIDIA 显卡
blacklist nouveau
blacklist nvidiafb
```

> ⚠️ `softdep xhci_hcd pre: vfio-pci` 是为了防止 01:00.2 被 xhci_hcd 抢先绑定；
> `softdep i2c_nvidia_gpu pre: vfio-pci` 防止 01:00.3 被 i2c-nvidia-gpu 抢占。

更新 initramfs 并重启生效：

```bash
sudo update-initramfs -u
# 重启后验证
lspci -nnk -s 01:00.0   # Kernel driver in use: vfio-pci
```

### 5.4 提取 VBIOS ROM（关键！）

笔记本独显的 vBIOS 不完整，**必须手动提取并挂载**，否则显卡无法初始化（黑屏/驱动失败）。

```bash
# 在未绑定 vfio 前，读取 PCI 设备 ROM
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom
sudo cat /sys/bus/pci/devices/0000:01:00.0/rom > /var/lib/libvirt/roms/rtx2060.rom
echo 0 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom
```

- 提取文件：`/var/lib/libvirt/roms/rtx2060.rom`（128 KB，已包含在本仓库 `config/rtx2060.rom`）
- 挂载方式：在虚拟机 XML 的 GPU hostdev 中添加 `<rom bar='on' file='...'/>`（见 `config/win10.xml`）

### 5.5 创建虚拟机 (virt-manager)

1. 新建虚拟机 → 选择本地安装介质/导入磁盘 → 选择 `win10.qcow2`
2. 固件选择 **UEFI (OVMF)**，开启 Secure Boot
3. CPU: `host-passthrough`，拓扑 1 socket × 8 core，vCPU=8
4. 内存: 4096 MB；磁盘: virtio (qcow2)，挂载 virtio-win.iso 装驱动
5. 网络: virtio 网卡，接 default NAT 网络
6. 添加硬件 → PCI Host Device → 依次添加 `01:00.0/01/02/03` 四个设备

关键 XML 要点（完整文件见 `config/win10.xml`）：

| 要点 | XML 配置 | 作用 |
|------|---------|------|
| CPU 直通 | `<cpu mode='host-passthrough'/>` | 性能接近原生 |
| Hyper-V 伪装 | `<vendor_id state='on' value='1234567890ab'/>` | **防 N 卡 Code 43 头号方案** |
| 子系统 ID 伪装 | `<qemu:property name='x-pci-sub-vendor-id' value='6058'/>`<br>`x-pci-sub-device-id value='14919'` | 伪装成联想笔记本显卡 (17aa:3a47) |
| vBIOS 挂载 | `<rom bar='on' file='/var/lib/libvirt/roms/rtx2060.rom'/>` | 修复笔记本独显 ROM 不完整 |
| 附属功能 | 01:00.1/.2/.3 全部 hostdev | 防止被宿主机驱动抢走 |
| 内存共享 | `access mode='shared'`（可选） | 为 Looking Glass 预留 |

> `6058 = 0x17aa`（Lenovo 子系统厂商），`14919 = 0x3a47`（Lenovo 子系统设备号）。

### 5.6 Windows 虚拟机内配置

1. 安装 virtio 驱动（virtio-win.iso 内 `virtio-win-gt-x64.exe`）
2. 安装 NVIDIA 官方驱动（RTX 2060）
3. 固定 IP：`192.168.122.20`（NAT 网段内，与脚本一致）
4. 远程管理可用 virt-manager 的 VNC/SPICE 窗口

### 5.7 HDMI EDID 欺骗器

- 拯救者笔记本 HDMI 口 **直接连在独显上**，虚拟机独显需要 EDID 信号才能输出完整分辨率
- 插入 HDMI 欺骗器后：解锁 1920×1080@60、硬件加速、正常刷新率
- 建议选**主动式 4K EDID 欺骗器**
- ⚠️ 串流时**不要拔掉**，否则画面会黑屏/变糊

---

## 6. Sunshine 安装与配置（虚拟机内）

### 6.1 安装

- 官方安装包：`Sunshine-Windows-AMD64-installer.exe`（Windows 虚拟机内安装）
- 或使用便携版（见 `config/sunshine/howto-sunshine-portable.txt`，含全部依赖 DLL，方便拷贝到另一台 Win11）
- 启动后 Web 管理界面：`https://192.168.122.20:47990`（默认用户名 `admin`，密码首次启动时显示/设置）

> 若用自定义 Web 端口/来源，需在 Sunshine 配置中设置（本机记录）：
> `csrf_allowed_origins = https://192.168.122.20:47990`

### 6.2 关键配置（Web 控制台 → 视频/音频）

| 配置项 | 推荐值 | 说明 |
|--------|--------|------|
| 编码器 | **nvenc** | NVIDIA 硬件编码，RTX 2060 专属 |
| 编解码器 | **HEVC (H.265)** | RTX 2060 不支持 AV1，HEVC 画质最佳 |
| 色彩空间 | **4:4:4** | 消除文字/UI 边缘色度压缩 |
| 码率 | **50–100 Mbps** | 码率不足会产生明显噪点 |
| NVENC 预设 | **P5 / P6** | 高质量编码 |
| FPS | 60 | 按需设置 |

### 6.3 添加应用

Web 控制台 → Applications 添加：

- `Desktop`（桌面串流，Moonlight 客户端中显示为 Desktop）
- `Steam Big Picture`（Steam 大屏模式）

### 6.4 防火墙

Windows 防火墙放行端口：`47984-48010`（TCP/UDP），Sunshine 安装时通常已自动添加规则。

---

## 7. Moonlight 安装与配置（宿主机）

### 7.1 安装

```bash
# 方式一：系统包 (当前使用 6.1.0)
sudo apt install moonlight

# 方式二：Flatpak
flatpak install flathub com.moonlight_stream.Moonlight
```

### 7.2 配对

1. 先启动 Win10 虚拟机，确认 Sunshine 已运行
2. 运行 `moonlight pair 192.168.122.20`，会显示 4 位 PIN
3. 在 Sunshine Web 界面 (https://192.168.122.20:47990) 的 PIN 输入框填入，完成配对

### 7.3 手动连接

```bash
# 直接串流桌面
moonlight stream 192.168.122.20 "Desktop" --resolution 1920x1080 --fps 60 --bitrate 20000
```

### 7.4 配置文件说明

- 实际配置：`~/.config/Moonlight Game Streaming Project/Moonlight.conf`
- 脱敏样例：`config/moonlight.conf.example`
- ⚠️ 真实文件包含客户端私钥，**不要公开分享**
- 已配对主机 `windows10` → `192.168.122.20:47989`，应用：Desktop、Steam Big Picture

---

## 8. 一键启动脚本

### 8.1 脚本内容

完整脚本见 `config/start-win10-moonlight.sh`（已安装到 `/usr/local/bin/start-win10-moonlight.sh`），内容照抄如下：

```bash
#!/bin/bash
# 一键启动 KVM Win10 + 自动连接 Moonlight
# 用法: start-win10-moonlight.sh

VM_NAME="win10"                    # 你的KVM虚拟机名称，如不同请修改
MOONLIGHT_IP="192.168.122.20"       # Win10 虚拟机IP，如不同请修改
MOONLIGHT_PORT=47989               # Moonlight默认端口(一般不需要改)
MOONLIGHT_RES="1920x1080"          # 分辨率
MOONLIGHT_FPS=60                   # 帧率
MOONLIGHT_BITRATE=20000            # 码率 kbps
MOONLIGHT_APP="Desktop"            # 要串流的应用名(桌面为Desktop)

# ---------- 确保 libvirt 网络已激活 ----------
echo ">>> 检查 libvirt default 网络..."
if ! virsh -c qemu:///system net-list --name 2>/dev/null | grep -qx "default"; then
    echo ">>> default 网络未激活，尝试启动..."
    virsh -c qemu:///system net-start default 2>/dev/null || \
    { echo "警告: 无法启动 default 网络，尝试定义..."; \
      sudo virsh net-define /etc/libvirt/qemu/networks/default.xml 2>/dev/null && \
      sudo virsh net-start default 2>/dev/null && sudo virsh net-autostart default 2>/dev/null; }
fi

# ---------- 启动虚拟机 ----------
echo ">>> 正在启动虚拟机: $VM_NAME"
if ! virsh -c qemu:///system list --all --name | grep -qx "$VM_NAME"; then
    echo "错误: 未找到名为 $VM_NAME 的虚拟机" >&2
    exit 1
fi

# 若未运行则启动
if ! virsh -c qemu:///system list --name | grep -qx "$VM_NAME"; then
    virsh -c qemu:///system start "$VM_NAME" || { echo "虚拟机启动失败" >&2; exit 1; }
fi
echo ">>> 虚拟机已启动/运行中"

# ---------- 等待系统完全启动 ----------
echo ">>> 等待 Win10 启动并出现 Moonlight 端口 (最多720秒)..."
TIMEOUT=720
SECONDS=0
until nc -z "$MOONLIGHT_IP" "$MOONLIGHT_PORT" 2>/dev/null; do
    if [ $SECONDS -ge $TIMEOUT ]; then
        echo "错误: 等待超时，请检查虚拟机IP ($MOONLIGHT_IP) 或网络" >&2
        exit 1
    fi
    sleep 3
done
echo ">>> Win10 已就绪，端口 $MOONLIGHT_PORT 可访问"

# ---------- 启动 Moonlight 连接 ----------
echo ">>> 启动 Moonlight 连接 $MOONLIGHT_IP ..."
if command -v moonlight >/dev/null 2>&1; then
    # 系统自带 moonlight(6.x)，stream 需要 <host> "<app>" 参数
    setsid nohup env QT_QPA_PLATFORM=xcb moonlight stream "$MOONLIGHT_IP" "$MOONLIGHT_APP" \
        --resolution "$MOONLIGHT_RES" --fps "$MOONLIGHT_FPS" --bitrate "$MOONLIGHT_BITRATE" \
        >/tmp/moonlight.log 2>&1 &
elif command -v moonlight-qt >/dev/null 2>&1; then
    setsid nohup moonlight-qt stream "$MOONLIGHT_IP" "$MOONLIGHT_APP" >/tmp/moonlight.log 2>&1 &
elif command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -qi moonlight; then
    setsid nohup env QT_QPA_PLATFORM=xcb flatpak run com.moonlight_stream.Moonlight stream "$MOONLIGHT_IP" "$MOONLIGHT_APP" --resolution "$MOONLIGHT_RES" --fps "$MOONLIGHT_FPS" --bitrate "$MOONLIGHT_BITRATE" >/tmp/moonlight.log 2>&1 &
else
    echo "错误: 未找到 moonlight / moonlight-qt 命令" >&2
    exit 1
fi

echo ">>> 完成！Moonlight 已连接 $MOONLIGHT_IP"
```

### 8.2 安装与使用

```bash
sudo cp config/start-win10-moonlight.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/start-win10-moonlight.sh

# 桌面快捷方式
cp config/start-win10-moonlight.desktop ~/Desktop/
# 直接运行
start-win10-moonlight.sh
```

### 8.3 脚本要点

- 使用系统会话 `qemu:///system`（曾因误用 `qemu:///session` 导致点击无反应）
- 自动确保 default NAT 网络激活
- 每 3 秒探测 47989 端口，最长等待 720 秒（虚拟机冷启动较慢）
- 依次尝试 `moonlight` → `moonlight-qt` → Flatpak 三种客户端

---

## 9. 故障排查

### 9.1 N 卡 Code 43 错误（设备管理器感叹号）

依次排查：

1. ✅ Hyper-V `vendor_id` 伪装（`<vendor_id state='on' value='1234567890ab'/>`）
2. ✅ 子系统 ID 伪装（`x-pci-sub-vendor-id=6058` / `x-pci-sub-device-id=14919`）
3. ✅ vBIOS ROM 挂载（`<rom file='rtx2060.rom'/>`）
4. ✅ 附属功能 (.1/.2/.3) 全部绑定 vfio-pci，防止被 xhci/i2c-nvidia-gpu 抢占
5. 确认宿主机 `/etc/modprobe.d/vfio.conf` 生效：`lspci -nnk -s 01:00.0` 显示 `Kernel driver in use: vfio-pci`

### 9.2 启动虚拟机死机/内核冻结

- 本机曾遇启动即冻结，通过**升级内核**（6.6.155-hwe）并**将内存从 8GB 降到 4GB** 解决
- 若复现，检查 `dmesg` 中 vfio/kvm 报错，或尝试在 GRUB 追加 `iommu=pt`

### 9.3 串流画面噪点/糊

- 码率不足所致 → Sunshine 码率拉到 50–100 Mbps
- **不要拔 HDMI EDID 欺骗器**（拔掉后黑屏/分辨率丢失）

### 9.4 Moonlight 点击没反应 / 无法连接

- 确认使用系统会话：`virsh -c qemu:///system list`
- 确认虚拟机 IP 固定为 `192.168.122.20`
- 确认 Sunshine 端口 47989 可达：`nc -zv 192.168.122.20 47989`
- 查看日志：`cat /tmp/moonlight.log`

### 9.5 直通后宿主机无法用独显

正常现象：RTX 2060 已完全交给虚拟机，宿主机使用核显（amdgpu）。需要独显时关闭虚拟机并解除 vfio 绑定。

---

## 10. 文件清单

```
win10-gpu-passthrough-moonlight/
├── README.md                        # 本文档
└── config/
    ├── win10.xml                    # 虚拟机完整配置 (libvirt domain XML) ★核心
    ├── vfio.conf                    # VFIO 驱动绑定配置 (modprobe.d)
    ├── blacklist-nouveau.conf       # nouveau 屏蔽配置
    ├── grub-default.txt             # GRUB 内核参数配置
    ├── networks-default.xml         # libvirt default NAT 网络定义
    ├── rtx2060.rom                  # 提取的 RTX 2060 vBIOS (128KB)
    ├── start-win10-moonlight.sh     # 一键启动脚本 ★核心
    ├── start-win10-moonlight.desktop# 桌面快捷方式
    ├── moonlight.conf.example       # Moonlight 客户端配置样例(脱敏)
    └── sunshine/
        ├── howto-sunshine-portable.txt  # Sunshine 便携版打包说明
        └── sunshine_addr.txt            # Sunshine Web 地址设置记录
```

> 已排除大文件：虚拟机磁盘 (win10.qcow2 62G / win11.qcow2 60G)、virtio-win.iso、
> Windows 软件安装包等，均不包含在本仓库。

---

## 11. 常用命令速查

```bash
# 虚拟机管理
virsh -c qemu:///system list --all          # 查看所有虚拟机
virsh -c qemu:///system start win10         # 启动
virsh -c qemu:///system shutdown win10      # 优雅关机
virsh -c qemu:///system destroy win10       # 强制断电
virsh -c qemu:///system edit win10          # 编辑配置

# 网络
virsh -c qemu:///system net-list            # 查看网络
virsh -c qemu:///system net-start default   # 启动 default 网络

# 验证直通
lspci -nnk -s 01:00                        # 确认 vfio-pci 绑定
for g in /sys/kernel/iommu_groups/*; do echo "$g: $(ls $g/devices)"; done

# 串流
start-win10-moonlight.sh                   # 一键启动+连接
moonlight stream 192.168.122.20 "Desktop" --resolution 1920x1080 --fps 60 --bitrate 20000
```

---

## 12. 致谢与参考

- [ArchWiki: PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
- [Sunshine 官方文档](https://docs.lizardbyte.dev/projects/sunshine/)
- [Moonlight 官方文档](https://moonlight-stream.org/)
- virt-manager / libvirt 官方文档

*本仓库内容基于真实部署环境整理，配置可直接对照使用，祝串流愉快！🎮*
