# sgs-love

QSanguosha（C++/Qt，2010-2014）→ LÖVE2D (Lua) 的重写项目。

当前进度：**A0 垂直切片** —— 协程规则引擎 + 杀/闪/桃迷你局 + headless 测试 + 人机 1v1 UI。

## 运行

```bash
# 1) 安装 LÖVE 11.5（任选其一）
brew install --cask love            # 系统安装
# 或把 love-11.5-macos.zip 解压到 tools/（已 gitignore）

# 2) 无头测试（不需要窗口，验证规则引擎）
love . --test
# 便携版: tools/love.app/Contents/MacOS/love . --test

# 3) 图形界面（人机 1v1）
love .
```

## 结构（详见 DESIGN.md）

```
src/core/   纯 Lua 规则引擎（零 love 依赖，headless 可测）
src/ui/     LÖVE 场景（菜单/牌桌）
src/sgs/    sgs.* 兼容层（阶段 B 吃进 diy/ 社区扩展）
tests/      BOT vs BOT 全量对局测试 + 多种子回归 + 卡牌守恒
assets/     字体（复用原版 DroidSansFallback）
```

## 路线图

A0 迷你局（本提交）→ A1 完整标准包 → B sgs 兼容层 → C 完整 UI/音频 → D 网络对局
