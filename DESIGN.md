# sgs-love — QSanguosha 的 LÖVE2D 重写

> 目标：以 Lua 为唯一语言，重写 QSanguosha（原版 78K 行 C++ + 20K 行 Lua 扩展），
> 对齐「三国杀」标准局核心体验，并最大化复用原版资产与社区 Lua 内容。

## 一、架构分层

```
┌─────────────────────────────────────────────┐
│ src/ui/        LÖVE 前端（唯一依赖 love 的层）│  场景/渲染/输入/音频
├─────────────────────────────────────────────┤
│ src/core/      纯 Lua 规则引擎（零 love 依赖）│  可 headless 测试、可复用为服务端
│   engine.lua   注册表：武将/卡牌/技能        │
│   card.lua     卡牌：花色/点数/类型          │
│   player.lua   玩家：体力/手牌/装备/阶段      │
│   skill.lua    技能基类 + 触发事件            │
│   room.lua     协程房间循环（阻塞语义核心）    │
│   standard.lua 标准包：杀/闪/桃 起步          │
│   ai.lua       基础 AI（可被原版 smart-ai 替换）│
├─────────────────────────────────────────────┤
│ src/sgs/       sgs.* 兼容 API 层             │  长出后直接吃 diy/ 社区扩展
└─────────────────────────────────────────────┘
tests/           headless 对局测试（love --test 运行，t.window=false）
tools/           便携 LÖVE（love.app，gitignore）
```

## 二、核心设计决策

### 1. 协程 = 阻塞式房间循环（对应原版 RoomThread）

原版 C++ 用信号量把游戏线程挂起等玩家响应；本引擎每个房间一个协程：

- 协程内：`self:askForCard(...)` 直觉上的阻塞调用，内部 `coroutine.yield(请求)`
- 协程外（驱动器）：`room:step(response)` 唤醒并注入响应，取回下一个请求
- 请求路由：人类玩家 → UI 事件等待；AI → 同步计算；网络对局 → socket 消息（阶段 D）

### 2. sgs.* 兼容层是社区内容的生命线

原版 diy/ 约 2 万行 Lua 扩展全部调用 swig 暴露的 `sgs.*` C++ API。
本引擎对外 API 按原版命名长出（sgs.Sanguosha / sgs.Player / sgs.AskType…），
兼容层成型后社区扩展近乎免费迁移。

### 3. 纯 Lua 核心 + LÖVE 只做表现层

core/ 禁止 require 任何 love 模块（CI 可校验），收益：

- 单测不依赖图形环境
- 阶段 D 网络服务端可直接以同一 core 跑 headless 房间

### 4. 资产复用

- 字体：`../QSanguosha/font/DroidSansFallback.ttf`（默认字体无 CJK）
- 图像/音频：按需接入 `../QSanguosha/image|audio/`
- 皮肤布局 JSON：阶段 C 用 serde…（哦不，用 dkjson/纯 Lua JSON 读取）

## 三、阶段计划

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| A0 | 骨架 + 杀/闪/桃迷你局 + headless 测试 + 最小 UI | ✅ 完成 |
| A1 | 标准包全量（锦囊/装备/延时锦囊/判定）+ 触发管线 + 六阶段回合 | ✅ 基本完成（武将技能仅少量样本） |
| B | sgs.* 兼容层 + diy/ 扩展加载器 | ⬜ 未开始 |
| C | 完整 UI（皮肤 JSON、动画、牌桌布局）+ 音频 | ⬜ 未开始 |
| D | LuaSocket 网络服务端 + 多人 | ⬜ 未开始 |

### 阶段内已实现（A1）

| 子系统 | 位置 | 说明 |
| --- | --- | --- |
| 触发管线 | `core/room.lua` `trigger()` | 按 priority 升序执行，返回 true 截断结算 |
| 事件枚举 | `core/skill.lua` | 对齐原版 `structs.h` 的 70+ 事件，含伤害/卡牌两条管线 |
| 回合阶段 | `core/room.lua` `_phase()` | RoundStart/Start/Judge/Draw/Play/Discard/Finish |
| 卡牌定义 | `core/cards.lua` | 基本牌 6 + 锦囊 15 + 延时锦囊 3 + 装备 11 |
| 距离 | `Room:distance()` | 环形座位差 + 攻/防马修正，最低 1 |
| 判定 | `Room:_judgeCard()` | 乐不思蜀/兵粮寸断/闪电；闪电未命中传给下家 |
| 标准牌堆 | `core/standard.lua` | 118 张，配比参考实体牌，LCG 确定性洗牌 |

## 五、开发约定

1. **core/ 禁止 require 任何 love 模块** —— UI 与 AI 只是「响应源」，规则只在 core/。
2. **改完 Lua 先跑 `./run-tests.sh`** —— 内含 `tools/lint_methods.py`，
   静态检查方法定义与调用语法是否匹配（点号/冒号错配踩过两次，见 commit 3e4c0ac）。
3. **新增卡牌**：在 `core/cards.lua` 用 `Cards.define` 登记，`Card.ZH`、
   `ctype`、效果分派由此统一，不要在 room.lua 里写 name 分支。
4. **新增武将技能**：`TriggerSkill:create(name, events, on_trigger, opts)`，
   注意 `TriggerSkill.create` 是点号定义，冒号调用会让实参整体右移一位。

## 四、运行方式

```bash
# 无头测试（不需要窗口）
tools/love.app/Contents/MacOS/love . --test
# 或已安装: love . --test

# 图形界面
tools/love.app/Contents/MacOS/love .
```
