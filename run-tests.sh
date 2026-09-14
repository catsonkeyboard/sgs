#!/bin/bash
# 无头跑：静态检查（方法调用语法）+ 单元/对局测试
# 真实显示器环境下 SDL dummy 非必需，CI/沙箱需要
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
exec env SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}" ./tools/love.app/Contents/MacOS/love . --test
