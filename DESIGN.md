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
| A1 | 标准包全量（锦囊/装备/延时锦囊/判定）+ 触发管线 + 六阶段回合 + 身份局 + 60 将技能 | ✅ 完成 |
| B | sgs.* 兼容层 + diy/ 扩展加载器 | 🚧 进行中（骨架可用，API 面待扩） |
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
| 身份 | `Room:setupRoles()` | 2~8 人配置；主公 +1 体力上限；身份暗置、阵亡亮牌 |
| 阵营胜负 | `Room:_checkIdentityWinner()` | 主公死→内奸独存则内奸胜否则反贼胜；反贼内奸全灭→主公方胜 |
| 奖惩 | `Room:_rewardAndPunish()` | 击败反贼摸 3 张；主公误杀忠臣弃光 |

### 武将技能库（`core/generals.lua`）

| 势力 | 数量 | 状态 |
| --- | --- | --- |
| 蜀 | 15 | ✅ 刘备/关羽/张飞/诸葛亮/赵云/马超/黄月英/黄忠/魏延/庞统/卧龙/刘禅/孟获/祝融/甘夫人 |
| 魏 | 15 | ✅ 曹操/司马懿/夏侯惇/张辽/许褚/郭嘉/甄姬/夏侯渊/张郃/徐晃/曹仁/典韦/荀彧/曹丕/乐进 |
| 吴 | 15 | ✅ 孙权/甘宁/吕蒙/黄盖/周瑜/大乔/陆逊/孙尚香/孙坚/小乔/太史慈/周泰/鲁肃/二张/丁奉 |
| 群 | 15 | ✅ 华佗/吕布/貂蝉/袁绍/颜良文丑/贾诩/庞德/张角/蔡文姬/马腾/孔融/纪灵/田丰/潘凤/邹氏 |

> 邹氏的【祸水】【倾城】是**国战专属**（建立在「武将明置/暗置」之上），
> 标准身份局无对应概念，已注册进名册但技能待 Phase B 的国战机制。
> 另：【名士】【随势】原版按国战条件判定，这里改用标准版/身份局阵营近似，代码内已注明。

技能三类写法：
- **触发技** `TriggerSkill:create(事件, 回调)` —— 回调返回 `true` 截断结算
- **转化技** `singleViewAs(名, 目标牌名, 过滤)` —— 手牌当别的牌用/打出
- **标记技** `markerSkill(名, {字段})` —— 只挂标记，由引擎在判定处查询

引擎侧查询的标记：`unlimited_slash` / `distance_mod` / `no_trick_range` /
`no_target_empty` / `auto_armor` / `savage_immune` / `xiangle` /
`no_target_tricks`（表，如【谦逊】禁止 snatch/indulgence）/
`slash_no_distance` / `no_slash` / `slash_extra_target`（【短兵】）/
`spade_as_heart`（【红颜】，目前只影响【天香】）/
`extra_dist_<牌名>`（逐牌名叠加距离，如【断粮】的 `extra_dist_supply_shortage`）。

回合内的临时增益/减益用 `grantMarker / revokeMarker` 往
`player.extra_skills` 注入标记技（【天义】拼点胜负），TurnStart 时撤销。

阶段跳过、翻面、拼点、收牌等通用原语见 `Room:skipPhase / turnOver / pindian /
obtain / takeOneCard / loseHp`。

## 四·五、兼容层（`src/compat/`，阶段 B）

| 文件 | 职责 |
| --- | --- |
| `sgs.lua` | `sgs` 全局：常量、Package/General、技能工厂、QVariant、`Sanguosha:cloneCard` |
| `exppattern.lua` | ExpPattern 卡牌匹配（`.|club|.|hand` 这类 `filter_pattern`） |
| `api.lua` | Room/Player/Card 的原版 API 别名 |
| `loader.lua` | 扫描 `diy/*.lua`，沙箱执行，把 Package 注册进 Engine |

三条硬规则：
1. **别名一律经 `define()` 安装，禁止无意覆盖引擎已有方法**（见下）。
2. **不做 `__index` 兜底**：未实现的方法照常报错，比静默返回 nil 好定位。
3. **事件/频率常量直接复用引擎的字符串值**，`events = { sgs.Damaged }`
   写进来就是 `{ "Damaged" }`，无需转换。

已用 `diy/moligaloo.lua`（改编自 `QSanguosha/extension-doc/1-Start.lua`）验证：
Package/General/OneCardViewAsSkill/TriggerSkill/`filter_pattern`/`cloneCard`/
`LoadTranslationTable` 均可跑通。

## 五、开发约定

1. **core/ 禁止 require 任何 love 模块** —— UI 与 AI 只是「响应源」，规则只在 core/。
2. **改完 Lua 先跑 `./run-tests.sh`** —— 内含 `tools/lint_methods.py`，
   静态检查方法定义与调用语法是否匹配（点号/冒号错配踩过两次，见 commit 3e4c0ac）。
3. **新增卡牌**：在 `core/cards.lua` 用 `Cards.define` 登记，`Card.ZH`、
   `ctype`、效果分派由此统一，不要在 room.lua 里写 name 分支。
4. **新增武将技能**：`TriggerSkill:create(name, events, on_trigger, opts)`，
   注意 `TriggerSkill.create` 是点号定义，冒号调用会让实参整体右移一位。
5. **以「他人」为主语广播的事件必须先校验主体**。`Room:trigger` 把技能**拥有者**
   作为 `player` 传入，而 `data.player` / `data.from` / `data.to` 才是事件主体。
   因此 `DrawNCards`、`Dying`、`Death`、`EventPhaseStart`、`FinishJudge` 这类事件
   上，技能必须写 `if data.player ~= player then return false end`，
   否则会在**别人的**摸牌/濒死/回合里触发自己的技能（【再起】【涅槃】踩过）。
   `Damaged` 用 `data.to`、`DamageCaused` 用 `data.from` 判断。
6. **会询问玩家（`askForXxx`）的技能，单测里必须放进协程跑**，否则主线程 `yield`
   直接报错。测试里统一用 `runInRoom(fn)` 包裹（见 `tests/test_game.lua`）。
7. **AI 主动使用转化技要登记 `CONVERT_TARGETS`**（`core/ai.lua`）。
   转化技默认只在「响应」（askForCard）时被考虑，出牌阶段不会主动转化，
   于是【武圣】【奇袭】【国色】【度势】这类技能在 AI 手里是废的。
8. **判队友不能只认「同身份」**：主公与忠臣同阵营但身份不同，
   `allies()` 必须取 `foes()` 的补集，否则【英魂】【缔盟】【直谏】找不到队友。
9. **凭空生成的牌（phantom）不能被任何「收牌」逻辑拿走**。
   `Room:obtain` 已统一拦截；若新写技能时要取 `data.card`，需先判
   `card.phantom`。反例：【奸雄】曾把【神速】的虚拟杀收进手牌，
   导致压测「卡牌不守恒 119 != 118」。
10. **技能实现要回查原版源码，不能凭记忆写**。反例：【再起】被记成
    「固定回复 1 点体力」，实为「翻 X 张牌、按红桃数回血」，
    前者让孟获每回合回血正好抵消 AI 输出，压测大面积卡死。

## 四、运行方式

```bash
# 无头测试（不需要窗口）
./run-tests.sh          # 静态检查 + 单测 + UI 测试

# 无头压力测试：1v1 / 4 人 / 5 人 / 8 人身份局各 25 局
# + 随机武将池身份局 + 逐将覆盖（每名武将各 3 局）
./run-soak.sh

# 图形界面
./run-game.sh
```

**无头模式靠 `conf.lua` 关窗口，不要用 `SDL_VIDEODRIVER=dummy`。**
dummy 驱动在 macOS 上建不出 OpenGL 上下文，LÖVE 会弹
「Unable to create OpenGL window」错误框后退出。`conf.lua` 在
`--test` / `--soak` 下把 `t.window` 关掉，用哪个 SDL 驱动都不会建窗口。
