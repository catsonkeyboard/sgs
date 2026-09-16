#!/bin/bash
cd "$(dirname "$0")"

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

exec ./tools/love.app/Contents/MacOS/love .
