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
│   bot.lua      基础 BOT：规则驱动的脚本对手（非机器学习/LLM）│
│   ai/          LLM 驱动的玩家（观察/动作/提示词/解析/降级）│
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
- 请求路由：人类玩家 → UI 事件等待；BOT → 同步计算；AI → 异步（可返回 thinking）；
  网络对局 → socket 消息（阶段 D）

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
| B | sgs.* 兼容层 + diy/ 扩展加载器 | ✅ 完成（国战与 bot 提示表按决策不做） |
| C | 完整 UI（皮肤 JSON、动画、牌桌布局）+ 音频 | 🚧 进行中（配置层与卡图/音频已通，布局待做） |

| `layout.lua` | 按 layout.json 的间距参数推导座位（自适应人数，缺配置退回原锚点） |
| `effects.lua` | 浮动伤害数字 + 出牌/阵亡横幅 |

已接入的真实素材（全部按路径引用，缺则退回自绘）：

- 卡牌图 `image/card/`（基本牌 snake_case、装备 CamelCase）
- 武将头像 `image/generals/avatar/<key>.png`（按 general.key 拼音）
- 体力勾玉 `image/system/magatamas/{0,3}.png`
- 势力图标 `image/kingdom/icon/<kingdom>.png`
- 桌面背景 `image/backdrop/table.jpg`、仪表盘底框 `dashboard*`
- 音效 `audio/**`（按 audio.json 键名）

**表现层事件**：core 新增 `Room:onEvent/emit`，目前发出 `useCard`（含目标
列表）/ `damage`（含来源）/ `death` / `skill` / `respond`（任何人打出的响应
牌：杀被闪、无懈、濒死求桃）/ `equip`（装备上阵，带槽位）/ `skillTarget`
（兼容层 `askForPlayerChosen` 指定到人，带技能名）。UI 在上面挂音频与动效——
出牌/响应/装备都有飞牌动画与音效，技能指定与伤害命中画「来源 → 目标」指向
箭头；core 只调回调，不依赖 UI；回调抛错会被捕获，绝不中断对局。

**动画说明**：原版 `defaultSkin.animation.json` 在这个皮肤里**是空的**（只有 `}`），
没有可复用的动效定义，因此 `effects.lua` 是自己实现的最小方案。

**过滤技（FilterSkill）**：统一入口 `Room:effSuit(p, card)`。
技能提供 `filter_view_filter(card) -> bool` 与 `filter_view(card) -> 花色`，
所有「看花色」的地方都走它，而不是直接读 `card.suit`：
延时锦囊判定（`cards.lua` 的 `judge`）、`JUDGE_HIT.*`、`雷击`、`刚烈`、
`再起`、`洛神`、`双雄`、`悲歌`、`天香`。

> 注意：**用点号调用** `s.filter_view_filter(card)`。过滤函数是「只接 card」
> 的普通函数，用冒号会把技能自身当第一个参数传进去（已踩过一次）。

兼容层的 `sgs.CreateFilterSkill` 做了适配：原版 `view_as` 返回一张改过的牌，
这里从中取出花色再交给 `effSuit`，因此 DIY 扩展的过滤技同样生效。

**主动技征询**：`Room:trigger` 里对人类玩家的非锁定技先走
`Room:askForSkillInvoke`（yield 出 `askForSkillInvoke` 请求），玩家点
「发动【技能】」或「不发动」；BOT 一律直接发动；锁定技（Compulsory/Wake）
不征询。此前人类玩家的技能是和 BOT 一样自动触发的，玩家没有选择权。

**待实机验证**（需要图形环境，headless 测不到）：

- 音效是否真的播放、音量是否合适
- 背景/框体的缩放与位置
- 座位布局在 8 人局下的观感
- 装备小图的尺寸
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

## 四·五五、皮肤与资源（`src/ui/`，阶段 C）

资源**自带**在 `assets/`（约 28MB，只取实际用到的部分：卡图、60 将头像、
勾玉、势力图标、背景、皮肤 JSON、卡牌与系统音效）。`Skin` 默认根就是 `assets/`，
仅当显式设置 `SGS_ASSET_ROOT` 时才指向别处。找不到资源仍会全部降级（查询返回
nil，UI 走内置默认值）。

> 历史：早期是按路径引用 `../QSanguosha`（57MB 全量），后改为自带。

| 文件 | 职责 |
| --- | --- |
| `src/ui/json.lua` | 极简 JSON 解析；**必须**先剥 `/* */` 与 `//` 注释（原版 skins/*.json 带） |
| `src/ui/skin.lua` | layout/image/audio/animation 四类配置的查询；卡牌图片按目录约定解析 |
| `src/ui/audio.lua` | 按 audio.json 的键名播放；缺文件/缺 love.audio/headless 一律静默 |

三条硬规则：

1. **资源缺失时安全降级**，绝不抛错、绝不打断对局。
2. **音频与图片都不参与规则判定**，只做表现。
3. skin/audio 只给**路径**，加载由 UI 层按需做——core 与 skin 都不碰
   `love.graphics` / `love.audio`。

已知差异：原版 layout.json 给的是「间距/内边距参数」而非绝对座位坐标，
座位锚点仍由本引擎自己算；目前已接入的是卡图、卡牌尺寸配置与音频映射。

## 四·五、兼容层（`src/compat/`，阶段 B）

| 文件 | 职责 |
| --- | --- |
| `sgs.lua` | `sgs` 全局：常量、Package/General、技能工厂、QVariant、`Sanguosha:cloneCard` |
| `exppattern.lua` | ExpPattern 卡牌匹配（`. | club | . | hand` 这类 `filter_pattern`） |
| `api.lua` | Room/Player/Card 的原版 API 别名 |
| `loader.lua` | 扫描 `diy/*.lua`，沙箱执行，把 Package 注册进 Engine |

三条硬规则：

1. **别名一律经 `define()` 安装，禁止无意覆盖引擎已有方法**（见下）。
2. **不做 `__index` 兜底**：未实现的方法照常报错，比静默返回 nil 好定位。
3. **事件/频率常量直接复用引擎的字符串值**，`events = { sgs.Damaged }`
   写进来就是 `{ "Damaged" }`，无需转换。

已用 `diy/` 下两份示例验证（`moligaloo.lua` 改编自 `extension-doc/1-Start.lua`，
`skillcard_demo.lua` 改编自 `extension-doc/4-SkillCard.lua`）：
Package/General/OneCardViewAsSkill/TriggerSkill/`filter_pattern`/`cloneCard`/
`LoadTranslationTable`/**SkillCard**（`CreateSkillCard` + `clone()` + subcards +
`will_throw` + `on_use`）均可跑通。

示例扩展的武将注册进引擎（测试直接 `getGeneral` 取用），但
`Standard.DEMO_PACKAGES` 把这三个包挡在正常对局的随机武将池外——
不然玩家开局会随机到「试炼武将」这类兼容层试作将；真正的社区扩展不受影响。

引擎侧为技能牌留了出口：`Room:_useSkillCard`。技能牌没有卡牌定义，
若走普通卡牌分派会落进「暂无结算规则」兜底，因此必须在分派前拦下。

## 四·六、阶段 B 已定与待办

### 已决策（不再反复）

1. ✅ **FilterSkill 全局生效** —— 已完成，见「过滤技」小节
2. ✅ **不做国战机制** —— 只做标准身份局。明置/暗置武将、阵法技、双将、
   `CreateArraySummonSkill` 一律不实现。
   → 影响：邹氏的【祸水】【倾城】纯属国战机制，她在名册里保留占位、
   无技能；原版 AI 文件中与国战相关的部分同样不移植。
3. ✅ **不消费原版 bot 提示表（`sgs.ai_*`）** —— 用 `src/core/bot.lua` 替代。
   表名继续保留（DIY 脚本会往里塞值，改名就崩），但引擎不读。

### 待办（按优先级）

1. ~~**标记类技能接进引擎**~~ ✅ 已完成
   新增 core 查询：`Room:attackRangeOf / maxCards / slashLimit /
   distanceLimitBonus / extraTargets / isProhibited`，并接到 `Room:distance`、
   出杀的距离与次数校验、弃牌上限、`_validateUse` 上。
   BOT 侧同步改用 `room:attackRangeOf`，否则标记技对 BOT 不可见。

2. ~~**卡牌包构造函数**~~ ✅ 已完成
   `sgs.CreateTrickCard / CreateBasicCard / CreateEquipCard / CreateWeapon /
   CreateArmor / CreateTreasure` 均已实现，登记进 `Cards.define`，
   效果走 `spec.on_effect / spec.on_use`。
   已知限制：**宝物**（CreateTreasure）本引擎无宝物槽，映射到防具槽。

3. ~~**询问类方法的语义补齐**~~ ✅ 已完成
   - `moveCardTo` 按 `place` 落到正确区域（hand / drawPile / discardPile / judge），
     以前一律丢进弃牌堆，导致「放回牌堆顶」「置入装备区」语义全错
   - `askForGuanxing` 返回原序（原来返回空表，会让按索引取牌的脚本崩）
   - `askForAG` 空池返回 nil；`askForCardShow` 明确不移走手牌
   - 仍是桩实现（有意为之，BOT 无对应交互界面）：`askForYiji` 一次分完并返回
     false 以终止原版的 `while` 轮询；`askForExchange` 退化成 `askForDiscard`

4. ~~**鸡肋（isJilei）**~~ ✅ 已完成
   `Player:isJilei(card)` 按 ctype（basic/trick/equip）或牌名判断；
   `setJilei / clearJilei` 设置。引擎在 `_validateUse` 拦下鸡肋牌，
   BOT 也不会把鸡肋牌拿出来响应。兼容层提供 `room:setJilei / clearJilei`。

5. ~~**ExpPattern 区域段**~~ ✅ 已完成
   未知区域名**不再静默放行**（以前 `return true`，写错的区域段会被忽略）。

6. **其余未实现的询问/表现层方法**：遇到再补，现在报错是响亮的，好定位。

> 阶段 B 至此收官：可加载原版 DIY 武将包与卡牌包，Package / General /
> ViewAs / Trigger / SkillCard / Filter / 标记类技能 / 询问类 API 均可用。
> 未做：国战机制（已决策不做）、原版 bot 提示表（已决策不消费）。

其他已实现的原版 API：`sgs.Card_Parse`（含 `@Class=` / `#obj:` 形式）、
`CardUseStruct` / `DamageStruct` / `LogMessage` / `CardMoveReason` / `qlist`、
`room:getThread():trigger`、`room:moveCardTo`、`Card:getSubcards():length()`、
`getSuitString()` / `getNumberString()`、区域与阶段常量、以及原版 bot 提示表
（`sgs.ai_view_as` 等，仅作容器——本引擎 BOT 不走这套）。

名称归一：原版脚本常写 `cloneCard("Duel")` 驼峰形式，`sgs.lowerCardName`
统一转 snake_case。

**询问类 API**（按原版扩展实际使用频次补齐）：`askForSkillInvoke`、
`askForUseCard`、`askForDiscard`、`askForCard`、`askForCardChosen`、
`askForPlayerChosen`、`askForChoice`、`askForPindian`、`askForCardShow`、
`askForAG`（含 `fillAG`/`takeAG`/`clearAG`/`closeAG`）、`askForYiji`、
`askForSuit`、`askForSinglePeach`、`askForUseSlashTo`、`askForGuanxing`、
`askForExchange`；辅助类 `setPlayerProperty`、`getCardPlace`、`getTag/setTag`、
`acquireSkill`/`detachSkillFromPlayer`、以及一批纯表现层的空实现
（`setEmotion`/`doLightbox`/`notifyMoveCards` 等）。

卡片移动统一走 `Room:_removeCardEverywhere`——**先从原区域摘除再放入新区域**，
避免同一张牌被登记两次。

仍未实现：阵法技、明置/暗置武将、鸡肋、FilterSkill 全局生效。

## 四·七、AI 玩家（`src/core/ai/`，LLM 驱动）

与 BOT **并列**的第三种响应源。接入点只有 `Driver`——规则引擎一行都没改：
座位标成 `"ai"` 后，它的请求会被转给 `Agent`。

| 文件 | 职责 |
| --- | --- |
| `view.lua` | 观察层：**信息隐藏**（别人手牌只给张数、未亮身份显示「未知」） |
| `memory.lua` | **跨步骤记忆**：决策史 + 身份判断 + 长期观察 |
| `actions.lua` | 合法动作枚举，复用 `canUseCardOn` / `viewAsCandidates` / `maxCards` |
| `prompt.lua` | 提示词：状态 + 记忆 + 候选编号 + 输出格式 |
| `parse.lua` | 解析与校验：越界/数量不符/类型混杂一律拒绝 |
| `agent.lua` | 响应源：异步状态机（thinking / ready）+ 重试 + 机械兜底 |
| `transport.lua` | 传输层（mock / curl / proxy），chat 与 responses 双协议 |
| `src/ui/ai_transport.lua` | LÖVE 实现：love.thread + curl/socket，主线程不阻塞 |
| `tools/ai_proxy.py` | 本机明文代理（标准库实现，零依赖） |

### 完全自主：规则 BOT 退出决策路径

早期版本是「关键决策问 AI，其余走 BOT」。实测一局 245 次请求里 **148 次（60%）
走的是 BOT**，而且全是出闪/出桃/无懈可击——恰恰最需要判断力的几类。现在：

| 设计 | 说明 |
| --- | --- |
| 8 种请求全部问 LLM | `Agent.ask_all` 默认 true |
| 兜底**不再调用** `Bot.make()` | 先**重试**（把失败原因回喂让它自纠），仍失败则**机械选择**第一个合法动作 |

机械兜底的意义：模型彻底失联时游戏也不会卡死，但**决策来源始终不是规则脚本**。
`Agent.fallback = "bot"` 仍可显式打开旧行为，留给对比测试。

### 跨步骤记忆（`memory.lua`）

没有记忆时每次调用都是孤立问答，AI 看不到「上轮谁打了我」「我上次判断谁是反贼」，
身份推理无从积累。有了记忆，每一步都能回放：

```
【你的决策史】共 5 步
  第1轮 出牌：使用【桃园结义】｜桃园结义全员回血，反贼自保助阵
  第1轮 出牌：使用【决斗】→P3｜决斗主公孙权，反贼直击目标
【你自己的长期观察】我是反贼P1刘备，目标杀主公P3孙权，其余身份未明。
【你上次对各自身份的判断】P3：主公
```

- 模型可在同一份 JSON 里回传 `beliefs`（身份判断）与 `note`（长期观察）。
  两者都是**可选**字段，只在有新判断时才写，避免每步多花 token。
- 键名归一：`2` / `P2` / `座位2` / `曹操` 都能映射到同一玩家；
  认不出的名字直接丢弃——**不能**写成 `nameOf(k) or k`，那样会凭空造出不存在的角色。
- 预算：超过 `max_steps`（默认 60）后把最早的折叠成一行统计摘要。

### 接入 TokenHub hy3（Responses API）

不是 Chat Completions，是 **Responses API**：请求用 `instructions` + `input`，
响应取顶层 `output_text`（没有就从 `output[].content[].text` 拼）。

```bash
export SGS_AI_URL="https://tokenhub.tencentmaas.com/v1/responses"
export SGS_AI_KEY="sk-..."
export SGS_AI_MODEL="hy3"
export SGS_AI_REASONING=none     # 必须，见下表
```

| 配置 | 单次耗时 | reasoning tokens |
| --- | --- | --- |
| 默认（不传） | 12.7s | 915 |
| `{"reasoning":{"effort":"low"}}` | 96.3s | 3227（low 不被识别，退回 high） |
| 顶层 `reasoning_effort: "low"` | 96.3s | 3227（完全无效） |
| **`{"reasoning":{"effort":"none"}}`** | **1.4~1.7s** | **0** |
| `max_output_tokens: 150` | 5.0s | 150（推理吃光配额，正文为空） |

一局 245 次调用：开思维链要一小时，关掉约 6 分钟。**这是能不能玩下去的关键开关。**

> **为什么用 curl 而不是 socket.http**：LÖVE 内置的 LuaSocket 3.0 没有 luasec，
> `ssl.https` 直接 require 失败，而 LLM 接口一律 HTTPS。系统 curl 支持 TLS，
> `io.popen` 实测可用。代价是阻塞，所以真正跑在 `love.thread` 的 worker 里。
>
> **密钥绝不进命令行**：请求头与请求体都写进 600 权限的临时文件，用
> `curl -H @文件` 读取。拼进命令行的话同机任何用户 `ps aux` 就能看见，
> 还会进 history 与进程审计日志。

<details>
<summary>为什么不给 LÖVE 装 luasec（已排除）</summary>

本机实测的四个障碍，任一个都够呛，何况一起出现：

1. **LÖVE 的 require 是沙箱化的** —— 报错信息里明确写着
   `no 'ssl/core' in LOVE game directories`，原生模块只能从游戏目录加载，
   不能像普通 Lua 那样从 `/usr/local/lib/lua/5.1/` 取。
2. **没有工具链** —— 无 luarocks，`/usr/local/lib/lua/5.1/` 与 luajit 头文件
   都不存在，得自己拉 LuaJIT 源码取 `lua.h`。
3. **链接方式特殊** —— LÖVE 把 LuaJIT 静态链接进去了，扩展模块不能链接
   libluajit，macOS 上要 `-undefined dynamic_lookup`；且 LÖVE.app 有签名，
   加载未签名 dylib 会被 library validation 拒绝。
4. **分发成本** —— 就算本机编译通过，Windows/Linux/macOS 各要带一份二进制。

替代思路「本地明文代理」（游戏 → `socket.http` 明文 → 127.0.0.1 代理 → HTTPS
转发）**已实现**（`tools/ai_proxy.py` + `Transport.Proxy`），两种模式用
`SGS_AI_TRANSPORT=proxy|curl` 切换。代理模式额外好处是**密钥不进游戏进程**。

线程里 `require "socket"` 实测可行（LuaSocket 被 LÖVE 编译进去了，不是文件模块），
所以代理模式也能放进 worker 线程，主线程照样不阻塞。
</details>

已知限制：

- 每步一次完整请求，没有 KV cache 复用；记忆越长 input 越大
- 弃牌等「多选」请求靠编号数组，模型偶尔给错数量 → 触发重试
- 关掉思维链后模型推理深度下降，身份判断主要靠提示词里的历史信息

### 【观星】：有界候选而非全排列

重排牌堆顶的全排列最多 5!=120 种，逐个编号会把提示词撑爆。
`actions.lua` 只枚举有代表性的子集：**原序 / 倒序 / 每张单独沉底 / 全部沉底**
（5 张时 8 个候选），每个候选预构造好 `{up=…, down=…}`，选中即交给引擎。
注意 up 的语义是 **up[1] 是牌堆顶**（下一张就摸到）。
人类玩家的观星 UI 也复用同一套候选摆成按钮（没做拖拽重排界面）。

### 联机对局的 AI（`SGS_NET_AI`）

`Host` 接受 `ai_agent`（Agent 实例）后，空座（或 `ai_seats` 指定的座位）
交给 LLM 而非规则 BOT；Driver 返回 `"thinking"` 时 tick 直接返回，
下一帧接着问，与本地牌桌同一模式。服务端（`server.lua`）用
`src/ui/ai_transport.lua` 的线程版传输层（serve.sh 在 love 下跑，
`love.thread` 可用），不会阻塞整个服务端；无 love 环境退回 core 同步实现。
环境变量 `SGS_NET_AI`：`1/on/all` = 全部空座，`"2,3"` = 指定座位（人来了人优先），
`off/0` = 关（默认，回到规则 BOT）。

## 五、开发约定

### 0. 术语：BOT ≠ AI（务必分清）

| 词 | 指代 | 位置 |
| --- | --- | --- |
| **BOT** | 规则驱动的脚本对手。无学习、无推理、无搜索，给定种子行为可复现 | `src/core/bot.lua` |
| **AI** | 由大语言模型（LLM）驱动的玩家 | `src/core/ai/`（传输层的 LÖVE 实现在 `src/ui/ai_transport.lua`） |
| `sgs.ai_*` | **原版**的 bot 提示表，名字沿用原版 API 不能改；本引擎 BOT 不消费 | `src/compat/sgs.lua` |

历史包袱：游戏行业长期把电脑对手统称 "AI"，本项目早期的 `ai.lua`、
`AI.makeAI()` 也是这个老用法，现已全部改名为 `bot.lua` / `Bot.make()`。
**新增代码一律用 BOT 指代规则对手**，把 AI 留给将来真正的 LLM 玩家。

1. **core/ 禁止 require 任何 love 模块** —— UI 与 BOT 只是「响应源」，规则只在 core/。
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
7. **BOT 主动使用转化技要登记 `CONVERT_TARGETS`**（`core/bot.lua`）。
   转化技默认只在「响应」（askForCard）时被考虑，出牌阶段不会主动转化，
   于是【武圣】【奇袭】【国色】【度势】这类技能在 BOT 手里是废的。
8. **判队友不能只认「同身份」**：主公与忠臣同阵营但身份不同，
   `allies()` 必须取 `foes()` 的补集，否则【英魂】【缔盟】【直谏】找不到队友。
9. **凭空生成的牌（phantom）不能被任何「收牌」逻辑拿走**。
   `Room:obtain` 已统一拦截；若新写技能时要取 `data.card`，需先判
   `card.phantom`。反例：【奸雄】曾把【神速】的虚拟杀收进手牌，
   导致压测「卡牌不守恒 119 != 118」。
10. **技能实现要回查原版源码，不能凭记忆写**。反例：【再起】被记成
    「固定回复 1 点体力」，实为「翻 X 张牌、按红桃数回血」，
    前者让孟获每回合回血正好抵消 BOT 输出，压测大面积卡死。

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
