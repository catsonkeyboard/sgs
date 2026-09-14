#!/bin/bash
# 启动联机服务端（阶段 D）。默认端口 9527，可用第一个参数覆盖。
cd "$(dirname "$0")/.."
exec ./tools/love.app/Contents/MacOS/love . --serve "${1:-9527}"
