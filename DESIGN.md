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

| 阶段 | 内容 | 完成标志 |
| --- | --- | --- |
| A0（本次） | 骨架 + 杀/闪/桃迷你局 + headless 测试 + 最小 UI | 人机 1v1 能玩完整小局 |
| A1 | 标准包全量（锦囊/装备/全武将技能）+ 原版协议对拍 | 标准局可玩 |
| B | sgs.* 兼容层 + diy/ 扩展加载器 | 原版扩展跑通 |
| C | 完整 UI（皮肤 JSON、动画、牌桌布局）+ 音频 | 视听对齐原版 |
| D | tokio…不，LuaSocket 网络服务端 + 多人 | 局域网对局 |

## 四、运行方式

```bash
# 无头测试（不需要窗口）
tools/love.app/Contents/MacOS/love . --test
# 或已安装: love . --test

# 图形界面
tools/love.app/Contents/MacOS/love .
```
