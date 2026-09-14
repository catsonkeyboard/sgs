#!/bin/bash
# 启动联机服务端（阶段 D）。
# 用法：./tools/serve.sh [端口] [座位数]
#   端口默认 9527，座位数默认 5（8 人为官方标准局）
cd "$(dirname "$0")/.."
exec ./tools/love.app/Contents/MacOS/love . --serve "${1:-9527}" "${2:-5}"
