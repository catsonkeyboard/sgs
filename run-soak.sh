#!/bin/bash
# 无头压力测试：多模式批量种子对局 + 逐将覆盖
#
# 无头能力由 conf.lua 关闭窗口提供，不要依赖 SDL_VIDEODRIVER=dummy：
# dummy 驱动在 macOS 上建不出 OpenGL 上下文，LÖVE 会弹
# 「Unable to create OpenGL window」错误框后退出。
cd "$(dirname "$0")"
set -e

exec ./tools/love.app/Contents/MacOS/love . --soak
