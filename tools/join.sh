#!/bin/bash
# 控制台客户端：连上联机服务端并自动应答。
# 用法：./tools/join.sh [名字] [host] [port]
cd "$(dirname "$0")/.."
exec ./tools/love.app/Contents/MacOS/love . --join "${1:-玩家}" "${2:-127.0.0.1}" "${3:-9527}"
