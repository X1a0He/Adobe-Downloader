#!/bin/bash

#  fix-helper.sh
#  Adobe Downloader
#
#  用于在 Helper 已安装但无法连接时，尝试修复并重启 LaunchDaemon。

set -e

LABEL="com.x1a0he.macOS.Adobe-Downloader.helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/${LABEL}"

trap 'echo; echo "按回车键关闭此窗口..."; read -r _' EXIT

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

echo "检查 LaunchDaemon 配置文件(plist)..."
echo "执行: sudo plutil -lint \"$PLIST\""
if ! sudo plutil -lint "$PLIST"; then
  echo
  echo "plist 校验失败，请尝试在 Adobe Downloader 中重新安装 Helper 后再运行本脚本。"
  exit 1
fi

echo
echo "当前 Helper 文件权限："
echo "执行: ls -l \"$PLIST\""
ls -l "$PLIST"
echo "执行: ls -l \"$HELPER\""
ls -l "$HELPER"
echo


if launchctl print system/"$LABEL" >/dev/null 2>&1; then
  echo "检测到已有运行中的 Helper，尝试停止..."
  echo "执行: sudo launchctl bootout system/\"$LABEL\""
  if ! sudo launchctl bootout system/"$LABEL"; then
    echo "警告: 停止 Helper 失败（可继续尝试后续修复），请查看上方错误信息。"
  fi
fi

echo "重新加载 LaunchDaemon 配置..."

# 优先使用新的 bootstrap / enable / kickstart 流程
if command -v launchctl >/dev/null 2>&1; then
  # bootstrap 会在 job 未加载时加载，在已加载时返回错误
  echo "执行: sudo launchctl bootstrap system \"$PLIST\""
  if ! sudo launchctl bootstrap system "$PLIST"; then
    echo "launchctl bootstrap 失败，请检查上方错误信息，并尝试在 Adobe Downloader 中重新安装 Helper。"
    exit 1
  fi

  echo "确保 Helper 处于启用状态..."
  echo "执行: sudo launchctl enable system/\"$LABEL\""
  if ! sudo launchctl enable system/"$LABEL"; then
    echo "launchctl enable 失败，请检查上方错误信息。"
    exit 1
  fi

  echo "尝试立即启动 Helper..."
  echo "执行: sudo launchctl kickstart -k system/\"$LABEL\""
  if ! sudo launchctl kickstart -k system/"$LABEL"; then
    echo "launchctl kickstart 失败，请检查上方错误信息。"
    exit 1
  fi
else
  echo "系统不支持新的 launchctl 子命令，尝试使用兼容模式加载..."
  echo "执行: sudo /bin/launchctl unload \"$PLIST\""
  if ! sudo /bin/launchctl unload "$PLIST"; then
    echo "警告: 卸载 LaunchDaemon 失败（可继续尝试加载），请查看上方错误信息。"
  fi
  echo "执行: sudo /bin/launchctl load -w \"$PLIST\""
  if ! sudo /bin/launchctl load -w "$PLIST"; then
    echo "launchctl load 失败，请检查上方错误信息。"
    exit 1
  fi
fi

echo
echo "操作已完成。"
echo "如果 Adobe Downloader 仍然提示「无法连接到 Helper」，"
echo "请将本终端窗口的全部输出内容复制后反馈给开发者。"
