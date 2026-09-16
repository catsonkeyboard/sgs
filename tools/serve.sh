#!/bin/bash
# 启动联机服务端（阶段 D）。
# 用法：./tools/serve.sh [端口] [座位数]
#   端口默认 9527，座位数默认 5（8 人为官方标准局）
cd "$(dirname "$0")/.."

# 本地 AI 配置：ai.env（KEY=VALUE，# 为注释；已在环境中设置的变量优先）。
# 兼容 Windows 编辑产生的 CRLF 行尾。
if [ -f ./ai.env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    [ "$k" = "$line" ] && continue
    if [ -z "${!k:-}" ]; then export "$k=$v"; fi
  done < ./ai.env
fi

exec ./tools/love.app/Contents/MacOS/love . --serve "${1:-9527}" "${2:-5}"
