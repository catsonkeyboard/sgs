# sgs-love

QSanguosha（C++/Qt，2010-2014）→ LÖVE2D (Lua) 的重写项目。

当前进度：**A1 + B + C 已完成** —— 标准包 60 将、sgs.* 兼容层（可加载原版 DIY
扩展）、接入原版美术与音频的牌桌 UI。D（网络对局）未开始。

## 运行

项目自带便携版 LÖVE（`tools/love.app`，11.5），无需额外安装。

```bash
./run-tests.sh        # 无头：静态检查 + 339 项单测（约 2 秒）
./run-soak.sh         # 无头：压测（60 将逐将覆盖 + 多种子回归 + 卡牌守恒）
./run-game.sh         # 图形界面
```

无头模式靠 `conf.lua` 在 `--test` / `--soak` 下关闭窗口实现，**不要**用
`SDL_VIDEODRIVER=dummy`（macOS 的 dummy 驱动建不出 OpenGL 上下文，会弹错误框）。

## 随时验证一段代码：`tools/lua.sh`

本机 PATH 里没有 `lua`，但 LÖVE 自带了 **Lua 5.1 / LuaJIT 2.1**（游戏运行时用的
就是它）。`tools/lua.sh` 把它包成一个 CLI，保证版本与游戏完全一致。

```bash
./tools/lua.sh 脚本.lua              # 运行脚本
echo 'print(_VERSION)' | ./tools/lua.sh -   # 跑一行代码（从标准输入读）
```

脚本内可直接 `require "src.core.*"`（package.path 已指向项目根）：

```lua
local Cards = require "src.core.cards"
print(Cards.get("slash").zh)   -- 杀
```

> 局限：`src/ui/*` 需要 `love.graphics` 等模块，windowless 下不可用。
> UI 相关请走 `./run-tests.sh`（`test_ui.lua` 用的是打桩的 love）。
> core/ 不依赖 love，可以放心在这里跑。

## 结构（详见 DESIGN.md）

```
src/core/     纯 Lua 规则引擎（零 love 依赖，headless 可测）
src/compat/   sgs.* 兼容层，加载 diy/ 下的原版社区扩展
src/ui/       LÖVE 场景（菜单/牌桌）+ 皮肤/音频/布局/动效
diy/          DIY 扩展示例（武将包）
tests/        BOT vs BOT 全量对局测试 + 多种子回归 + 卡牌守恒
tools/        lint_methods.py（点号/冒号检查）、lua.sh、love.app
assets/       字体（复用原版 DroidSansFallback）
```

**术语**：`BOT` = 规则驱动的脚本对手（`src/core/bot.lua`，无学习/推理/搜索）；
`AI` 留给将来由 LLM 驱动的玩家。详见 DESIGN.md「五、开发约定 0」。

## 路线图

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| A0 | 骨架 + 迷你局 + headless 测试 | ✅ |
| A1 | 标准包全量 + 60 将技能 | ✅ |
| B | sgs.* 兼容层 + diy/ 扩展加载器 | ✅（国战机制与 bot 提示表按决策不做） |
| C | 完整 UI（皮肤/布局/音频/动效） | ✅（待实机验证观感） |
| D | LuaSocket 网络服务端 + 多人 | ⬜ 未开始 |
