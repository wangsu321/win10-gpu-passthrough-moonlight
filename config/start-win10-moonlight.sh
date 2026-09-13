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
