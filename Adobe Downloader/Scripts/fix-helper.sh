#!/bin/bash

#  fix-helper.sh
#  Adobe Downloader
#
#  用于在 Helper 已安装但无法连接时，尝试修复并重启 LaunchDaemon。

set -e

LABEL="com.x1a0he.macOS.Adobe-Downloader.helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/${LABEL}"

echo "=== Adobe Downloader Helper 修复工具 ==="
echo

if [ ! -f "$PLIST" ] || [ ! -f "$HELPER" ]; then
  echo "未找到 Helper 的系统文件："
  echo "   $PLIST"
  echo "   $HELPER"
  echo
  echo "请先在 Adobe Downloader 的「设置 - Helper 设置」中点击「重新安装」，"
  echo "完成重新安装后，再运行本脚本进行修复。"
  exit 1
fi

echo "正在尝试重启并启用 Helper 对应的 LaunchDaemon..."
echo

# 尽量先将已有的 job 退出，忽略错误
if launchctl print system/"$LABEL" >/dev/null 2>&1; then
  echo "检测到已有运行中的 Helper，尝试停止..."
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
fi

echo "重新加载 LaunchDaemon 配置..."

# 优先使用新的 bootstrap / enable / kickstart 流程
if command -v launchctl >/dev/null 2>&1; then
  # bootstrap 会在 job 未加载时加载，在已加载时返回错误，忽略错误即可
  sudo launchctl bootstrap system "$PLIST" 2>/dev/null || true

  echo "确保 Helper 处于启用状态..."
  sudo launchctl enable system/"$LABEL" 2>/dev/null || true

  echo "尝试立即启动 Helper..."
  sudo launchctl kickstart -k system/"$LABEL" 2>/dev/null || true
else
  echo "系统不支持新的 launchctl 子命令，尝试使用兼容模式加载..."
  sudo /bin/launchctl unload "$PLIST" 2>/dev/null || true
  sudo /bin/launchctl load -w "$PLIST"
fi

echo
echo "操作已完成。"
echo "如果 Adobe Downloader 仍然提示「无法连接到 Helper」，"
echo "请将本终端窗口的全部输出内容复制后反馈给开发者。"

