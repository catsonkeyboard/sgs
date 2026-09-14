#!/bin/bash
# 图形联机客户端：连上服务端后进入联机牌桌。
# 用法：./tools/play.sh [名字] [host] [port]
#   默认连 127.0.0.1:9527；先跑 ./tools/serve.sh
cd "$(dirname "$0")/.."
exec ./tools/love.app/Contents/MacOS/love . --client "${1:-我}" "${2:-127.0.0.1}" "${3:-9527}"
