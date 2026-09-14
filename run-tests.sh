#!/bin/bash
# 无头跑：静态检查（方法调用语法）+ 单元/对局测试
#
# 不设 SDL_VIDEODRIVER=dummy：无头靠 conf.lua 在 --test 时不建窗口实现，
# dummy 驱动在 macOS 上建不出 OpenGL 上下文，反而会弹「Unable to create
# OpenGL window」错误框。留空即可，用默认驱动但没有窗口。
cd "$(dirname "$0")"
set -e

echo "== 静态检查：方法定义/调用语法 =="
if command -v python3 >/dev/null 2>&1; then
  PY=python3
else
  PY=/Users/liming/.workbuddy/binaries/python/versions/3.13.12/bin/python3
fi
"$PY" tools/lint_methods.py src tests

echo
echo "== 对局与单元测试 =="
exec ./tools/love.app/Contents/MacOS/love . --test
