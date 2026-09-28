#!/usr/bin/env bash
# 双击运行：把本机 Claude Code 接进飞书。
# 每次都拉取最新的 install.sh，安装逻辑只维护一份。
clear
printf '\n  正在准备安装，请稍候…\n\n'
URL="https://raw.githubusercontent.com/Minerva67/lark-coding-agent-bridge/main/install.sh"
if curl -fsSL --max-time 30 "$URL" -o /tmp/lark-bridge-install.sh; then
  bash /tmp/lark-bridge-install.sh
  code=$?
else
  printf '\n  下载安装脚本失败，请检查网络后再双击一次。\n'
  code=1
fi
rm -f /tmp/lark-bridge-install.sh
printf '\n  按回车键关闭这个窗口。'
read -r _
exit $code
