#!/bin/bash
# 无头跑测试；真实显示器环境下 SDL dummy 非必需，CI/沙箱需要
cd "$(dirname "$0")"
exec env SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}" ./tools/love.app/Contents/MacOS/love . --test
