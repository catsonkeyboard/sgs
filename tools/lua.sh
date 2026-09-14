#!/bin/bash
# tools/lua.sh —— 用 LÖVE 内置的 LuaJIT 运行一个 Lua 脚本
#
# 为什么需要它：本机 PATH 里没有 lua/luajit，但 LÖVE 自带了
#   Lua 5.1 / LuaJIT 2.1（游戏运行时用的就是它）。这个脚本把它
#   包成一个可用的 CLI，保证验证代码时的解释器版本与游戏完全一致。
#
# 用法：
#   ./tools/lua.sh 脚本.lua          运行一个脚本
#   echo 'print(1)' | ./tools/lua.sh -   从标准输入读（跑一行代码很方便）
#
# 注意：src/ui/* 需要 love.graphics 等模块，windowless 模式下不可用；
#       UI 相关请走 ./run-tests.sh（test_ui.lua 用的是打桩的 love）。
#       core/ 不依赖 love，可以放心在这里跑。
set -e

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LOVE="$ROOT/tools/love.app/Contents/MacOS/love"

if [ ! -x "$LOVE" ]; then
  echo "找不到 LÖVE：$LOVE" >&2
  exit 1
fi

if [ -z "$1" ]; then
  echo "用法: ./tools/lua.sh <脚本.lua>   或   echo 'print(1)' | ./tools/lua.sh -" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "$1" = "-" ]; then
  SCRIPT="$TMP/_stdin.lua"
  cat > "$SCRIPT"
elif [ -f "$1" ]; then
  SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  echo "找不到脚本: $1" >&2
  exit 1
fi

# 无窗口：与 --test 同一套机制（conf.lua 里 t.window = false）
printf 'function love.conf(t) t.window = false end\n' > "$TMP/conf.lua"

# package.path 指向项目根，脚本里可以直接 require "src.core.*"
cat > "$TMP/main.lua" <<EOF
package.path = "$ROOT/?.lua;" .. package.path
function love.load()
  local ok, err = pcall(dofile, "$SCRIPT")
  if not ok then print("[错误] " .. tostring(err)) end
  love.event.quit()
end
EOF

"$LOVE" "$TMP"
