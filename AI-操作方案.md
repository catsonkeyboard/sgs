# AI 是如何操作游戏的 —— 本项目现有方案

> 本文档描述 `sgs` 当前（F 阶段）的 AI 玩家完整实现：LLM 如何接到规则引擎上、
> 每一步决策的完整数据流、以及失联/出错时的兜底行为。全部内容以源码为准。
>
> 术语约定：**BOT** = 规则驱动的脚本对手（`src/core/bot.lua`，无推理）；
> **AI** = 由 LLM 驱动的玩家（`src/core/ai/`）。两者是并列的响应源，AI 路径**不调用** BOT。

---

## 1. 一句话概括

**AI 不直接操作游戏，它只回答引擎抛出的「询问」**。规则引擎以协程方式运行，
走到任何需要玩家决策的地方就 `coroutine.yield` 出一个请求；AI 的职责就是把这个请求
翻译成「观察 → 候选动作 → 提示词 → LLM → 解析校验 → 合法响应」这一条流水线，
再把响应 `resume` 回协程。LLM 从头到尾**只在带编号的合法候选里挑一个**，
结构上不可能产生非法动作。

## 2. 总体架构

```text
┌─────────────────────────────────────────────────────────────────────┐
│ 规则引擎 src/core/room.lua（协程）                                    │
│   askForUseCard / askForCard / askForSkillInvoke / askForDiscard …   │
│   → coroutine.yield(req)  挂起，room.pending = req                    │
└──────────────┬──────────────────────────────────────────────────────┘
               │ room:step(resp) = coroutine.resume(co, resp)
┌──────────────┴──────────────────────────────────────────────────────┐
│ 驱动器 src/core/driver.lua —— 三种响应源的唯一路由                    │
│   player:controlMode() == "human" → 返回 "human"，UI 等点击           │
│   player:controlMode() == "ai"    → Agent:respond(req, room)         │
│                                     ├─ 还没结果 → 返回 "thinking"     │
│                                     └─ 有结果   → room:step(resp)    │
│   其余（bot/默认）                → 规则 BOT 同步出结果               │
└──────────────┬──────────────────────────────────────────────────────┘
               │
┌──────────────┴──────────────────────────────────────────────────────┐
│ Agent 状态机 src/core/ai/agent.lua（异步：start → 轮询 poll）          │
│                                                                      │
│  ① actions.lua   枚举当前请求的全部合法候选，编上号                    │
│  ② view.lua      构造「该玩家视角可知」的观察（信息隐藏）              │
│  ③ memory.lua    该座位的决策史 + 身份判断 + 长期观察                  │
│  ④ prompt.lua    观察+记忆+候选+输出格式 → {system, user}             │
│  ⑤ transport     submit/poll/cancel 三方法（Mock/Curl/Proxy/线程版）  │
│  ⑥ parse.lua     LLM 原始输出 → 编号 → 校验 → 引擎响应对象             │
│  ⑦ 失败路径       重试（错误回喂）→ 机械兜底（不调规则 BOT）           │
└─────────────────────────────────────────────────────────────────────┘
```

## 3. 引擎与 AI 的接口：协程询问

引擎内的规则代码（技能、结算）写成「直觉上的阻塞调用」，实际是协程挂起：

```lua
-- src/core/room.lua
function Room:askForUseCard(player)
  return coroutine.yield({ type = "askForUseCard", player = player })
end
```

- 协程内：`askForXxx` 即问即停，`room.pending` 指向当前请求；
- 协程外：`room:step(response)` 把响应注入协程，`room.pending` 变为下一个请求。

共有 **8 种询问类型**（AI 全部支持）：

| 请求类型 | 含义 | 典型来源 |
| --- | --- | --- |
| `askForUseCard` | 出牌阶段用什么牌（或结束） | 每个出牌阶段 |
| `askForCard` | 被要求打出指定牌（闪/桃/无懈可击/杀） | 被杀、濒死、南蛮、决斗 |
| `askForSkillInvoke` | 是否发动某技能 | 触发技征询 |
| `askForDiscard` | 弃 n 张手牌 | 弃牌阶段 / 过河拆桥类 |
| `askForChooseCard` | 从展示牌里拿一张 | 五谷丰登 |
| `askForDiscardFrom` | 替对手挑一张弃掉 | 过河拆桥结算 |
| `askForChoice` | 多选一 | 各类技能分支 |
| `askForGuanxing` | 重排牌堆顶 | 【观星】 |

**控制权的归属**由玩家对象自己决定（`src/core/player.lua`）：

```lua
function Player:controlMode()      -- "human" / "bot" / "ai"
function Player:setControl(mode)   -- 随时切换
```

`Driver:advance()` 每次循环取出 `room.pending`，按 `controlMode()` 路由。
AI 路径返回 `"thinking"` 时立即让出（UI 下一帧再调一次 `advance`），
所以**主线程永远不会为等 LLM 阻塞**。

> Driver 里 AI 抛异常时打印日志并返回被动响应，**绝不静默回落规则 BOT**
> —— 那会把 AI 的 bug 伪装成「它打得像 BOT」，排查时无法区分。
> 正常路径上这个分支也到不了：Agent 内部已整体 `pcall`。

## 4. 动作枚举：AI 决策的地基（`src/core/ai/actions.lua`）

**LLM 不做自由生成，只在候选编号里挑**。`Actions.enumerate(req, room)` 对每种请求
穷举全部合法动作，每个动作带连续编号 `id`（这就是 LLM 要输出的东西）：

| 动作 kind | 出现在哪些请求 | 说明 |
| --- | --- | --- |
| `use` | askForUseCard | 每张可出的牌 × 每个合法目标 = 一个候选，desc 里带目标体力/手牌数/距离 |
| `card` | askForCard | 每张能打出的实体牌一个候选 + 转化技候选 |
| `discard` | askForDiscard | 每张手牌一个候选，AI 需返回多个编号 |
| `choose` | askForChooseCard / askForDiscardFrom | 每张可选牌一个候选 |
| `invoke` | askForSkillInvoke | 发动 / 不发动，两个候选 |
| `choice` | askForChoice | 每个选项一个候选 |
| `guanxing` | askForGuanxing | 见下 |
| `pass` | askForUseCard / askForCard | 结束出牌 / 不打出 |

关键设计：

- **规则判断全部复用引擎现成校验**（`Room:canUseCardOn`、`canUseCardOn` 的距离/
  次数/鸡肋过滤、`isJilei`、判定区同名延时锦囊去重），AI 与 BOT、人类玩家走同一套
  判定，不会出现「AI 能出、玩家不能出」。
- **转化技也枚举进去**：不是只看固定清单，而是先扫该玩家所有 `view_as` 技能的
  `result_name`（如【武圣】变杀），再并上兜底清单（顺手牵羊/决斗等 8 个常用目标）；
  虚拟牌由 `skill:view_as(args)` 现场生成、挂在动作上，不进任何牌区，不影响卡牌守恒。
- **观星不搞全排列**：5!=120 种排列会把提示词撑爆，只枚举代表性子集——
  原序 / 倒序 / 每张单独沉底 / 全部沉底，每个候选预构造好 `up/down` 列表。
- **满血不吃桃、醉酒不再酒**这类「合法但无意义」的动作在枚举阶段就剔除
  （`activelyUsable`），候选列表更短、LLM 更不容易选错。

`Actions.worthAsking(req, {all_requests=true})`：Agent 默认 `ask_all = true`，
**所有请求（包括出闪/出桃/无懈这类高频响应）都交给 LLM**。
设 `ask_all = false` 可退回「只问决策类请求」的省流模式
（`LLM_WORTHY` 表控制哪些类型值得问）。

## 5. 观察层：信息隐藏（`src/core/ai/view.lua`）

把房间状态压成「**当前行动者视角下可知**」的纯数据（可直接 JSON 化）：

- **自己**：完整手牌（id/花色/点数/中文名）、技能名（过滤掉带「·」的内部记账子技能）、
  攻击范围、体力、装备、判定区、**自己的身份**（当然可知）；
- **别人**：手牌**只给张数**、身份**只给已亮明的**（主公、或阵亡翻开的）否则「未知」、
  体力/装备/判定区/距离/存活/势力；
- **战况**：最近 12 条对局日志（做时序推理用）。

> 信息隐藏是**硬要求**：少了这层，AI 等于开图作弊——身份局里玩家一眼看得出来，
> 而且调试时也搞不清 AI 的判断到底是「推理出来的」还是「看见的」。

## 6. 记忆：跨步骤积累推理（`src/core/ai/memory.lua`）

每个座位一份 `Mem`（`Agent.memories[seat]`），三个部分：

| 结构 | 内容 | 更新方 |
| --- | --- | --- |
| `steps` | 走过的每一步：轮次、阶段（出牌/响应/技能/弃牌…）、选了什么、当时的理由 | Agent 自动记录 |
| `beliefs` | 对各自身份的最新判断（主公/忠臣/反贼/内奸/未知，白名单校验，座位号或玩家名指代均可） | LLM 在输出里回传 `beliefs` 字段 |
| `notes` | AI 自己维护的一句长期观察（≤300 字） | LLM 在输出里回传 `note` 字段 |

- 超过 `max_steps`（默认 60）后，最早的步骤**折叠**成分类统计
  （「更早：出杀×5、出闪×3…」），细节不丢全局，token 不爆。
- 记忆在提示词里的位置是刻意的：**观察 → 决策史 → 候选动作**。
  顺序反了会让模型先锚定选项、再找理由。
- 实际效果（真机日志）：AI 第 1 轮用桃园结义（理由「反贼自保助阵」）、
  决斗主公，长期观察里写「我是反贼 P1 刘备，目标杀主公 P3 孙权」——
  后续每一步请求都会完整回放这些内容，它会基于此修正身份判断。

## 7. 提示词（`src/core/ai/prompt.lua`）

`Prompt.build` 返回 `{system=, user=}`，直接进对话接口。

**System**（固定）：三国杀身份局规则要点 + 四条「像真人一样思考」：

1. 推算身份（用决策史回看谁在帮谁）；
2. 因人施策（对空城留牌、对反馈少用锦囊、对奸雄别送牌——先看技能再决定出什么）；
3. 算得失（牌现在值不值、残血的人救不救——他可能是敌人）；
4. 记住教训（决策史里自己写过的理由，错了就改）。

**User**（每步拼装）：

```text
第 N 轮，当前阶段…，存活 X 人，牌堆剩 Y 张
【你】名字（武将）身份 体力 攻击范围 技能
  手牌：1)黑桃7-杀 2)红桃5-桃 …
【其他角色】座位2 曹操（奸雄）未知 体力 3/4 手牌 5 张 距离 1 …
【最近战况】…
【你的决策史】共 5 步 …            ← memory:render
【你自己的长期观察】…              ← notes
【你上次对各自身份的判断】P3：主公 ← beliefs
【上一次的输出被拒绝】…            ← 仅重试时
【现在需要你决定】出牌阶段：可以使用一张牌，或结束出牌
【合法动作】只能从中选择：
  1. 出黑桃7-杀 → 曹操（体力 3/4，手牌 5 张，距离 1）
  2. 以【武圣】当作【杀】→ 孙权（…）
  3. 结束出牌
【输出格式】只输出一行 JSON，不要 markdown 代码块…
{"action": <编号>, "reason": "<一句话理由，中文，20 字以内>"}
多选时：{"actions": [<编号>, <编号>], "reason": "..."}
可选字段：beliefs / note（有新判断才写）
```

原则：**只描述、不代劳**——规则结论（距离、合法目标）已在候选里算好，
提示词不重复教规则；**输出格式要窄**——只要编号，越窄解析越稳。

## 8. 解析与校验：默认 LLM 会犯错（`src/core/ai/parse.lua`）

对模型输出的处理步步设防，任何一环不对就返回 `(nil, 错误原因)`：

1. **抠 JSON**（`extractJson`）：剥 ``` 代码块、忽略前后寒暄，用括号配对
   （含字符串转义处理）找到第一个完整 JSON 对象；
2. **归一化编号**：`action: 3` / `actions: [1,2]` 都认，字符串数字 `"3"` 也认；
3. **越界拒绝**：编号不在候选表里直接拒；
4. **数量校验**：弃牌必须正好 n 张，其余请求必须 1 个，多了少了都拒；
5. **混合类型拒绝**：一次选了不同 kind 的动作说明模型没看懂，拒；
6. **执行前再校验**：`use` 动作映射回真实 Card/Player 后，还会再跑一遍
   `Room:canUseCardOn`（防虚拟牌/转化技的边界情况）；弃牌查重复选同一张；
7. **可选元信息**（`beliefs`/`note`/`reason`）不做硬校验，解析失败也不让整步作废，
   交给 Memory 侧过滤（白名单 + 长度限制，防止模型输出垃圾撑爆提示词）。

## 9. Agent：异步状态机 + 重试 + 机械兜底（`src/core/ai/agent.lua`）

对外只有一个方法 `Agent:respond(req, room) → (resp, "ready") | (nil, "thinking")`，
上层（UI 每帧 advance）不需要任何结构改动：

```text
首次被问 ──► _start：枚举候选 →（0 个候选直接机械应答，通常是"结束出牌"）
                   组提示词（观察+记忆+候选）→ transport:submit → "thinking"
之后轮询 ──► _poll：超时检查（默认 30s，超时 cancel）
                   transport:poll → 还没结果 → "thinking"
                                → 有结果 → Parse.response
                                     ├─ 通过：记入记忆 → 触发 on_decision → (resp,"ready")
                                     └─ 失败：_retryOrMechanical
```

**失败路径（关键设计：规则 BOT 不参与决策）**：

```text
解析失败 / 接口报错 / 超时
   │
   ├─ 还有重试额度（默认 1 次）
   │    → 把失败原因回喂给模型重问：
   │      「你上一次的输出无法使用（动作编号越界: 9）。请只输出符合格式的一行 JSON，
   │        action 必须是后面列出的编号之一。」
   │
   └─ 重试耗尽 → 机械兜底（_mechanical，纯机械规则，不调 bot.lua）：
        askForSkillInvoke   → 不发动
        askForGuanxing      → 保持原序
        askForDiscard       → 依序弃满 n 张
        askForChooseCard 等 → 选第一个合法项（不给会违规卡死）
        askForUseCard /
        askForCard          → **被动放弃**（nil）
```

> 出牌/响应类为什么兜底是「被动」而不是「选第一个」：模型失联时，
> 「乱出一张牌」可能把桃/无懈在错误时机打出去，比「什么都不做」危险得多。
> 必须给答案的请求（弃牌/选牌）才机械执行，否则会违规卡死整局。

整个 `respond` 包一层 `pcall`：AI 层任何内部异常都被吞掉并转为机械应答，
保证这条链路**永远不会向引擎抛异常**（Driver 的保险分支永远不触发）。

**运行统计**（`agent.stats`）：`asked`（问了几次）/ `by_ai`（模型成功）/
`retried` / `mechanical`（机械兜底）/ `timeouts` / `errors[]` / `rejections[]`，
`tools/ai-demo.lua` 结束时会打印汇总。

## 10. 传输层：三个实现 + 线程版（`src/core/ai/transport.lua`、`src/ui/ai_transport.lua`）

统一接口（可替换而 AI 逻辑不动）：

```lua
submit(prompt) -> bool     -- 提交 {system=, user=}
poll()  -> nil | {ok, text, err}   -- nil = 还没结果，不阻塞
cancel()
```

| 实现 | 位置 | 通信方式 | 适用 |
| --- | --- | --- | --- |
| `Mock` | core/ai/transport.lua | 不联网，预设响应队列，可模拟延迟 | 单测/跑通链路 |
| `Curl` | core/ai/transport.lua | `io.popen` 调系统 curl 直连 HTTPS（**阻塞**） | headless 脚本 / 线程内 |
| `Proxy` | core/ai/transport.lua | LuaSocket 明文 HTTP → 本机代理 | 测试 / 线程内 |
| `Threaded` | ui/ai_transport.lua | **love.thread 后台线程**，主线程每帧 poll | 游戏/服务端（正式路径） |

**为什么是 curl + 线程**：LÖVE 内置 LuaSocket 没有 luasec（`ssl.https` 直接
require 失败），而 LLM 接口一律 HTTPS；curl 一次 1~3 秒又不能放主线程。
于是主线程只把请求体丢进 Channel，线程阻塞地跑网络，UI 每帧 poll 取结果。
线程体故意不 require 任何项目模块（LÖVE 线程是独立 Lua 状态，package.path
不共享），协议差异（请求体构造/响应解析）复用 core 层的单一实现。

**安全细节**：密钥与请求体都写进 **chmod 600 的临时文件**，用 curl 的
`-H @文件` 传参——直接拼命令行的话，同机任何用户 `ps aux` 就能看到 key。
被 cancel 的请求结果回来时用 `discard` 计数丢弃，不会拿旧答案冒充新决策。

**双协议**（`SGS_AI_PROTOCOL` 控制，默认按 URL 猜）：

| 协议 | 请求形态 | 取值 |
| --- | --- | --- |
| `chat`（OpenAI Chat Completions） | `messages:[{system},{user}]`，temperature 0.2，max_tokens 300 | `choices[1].message.content` |
| `responses`（OpenAI Responses API，hy3 走这个） | `instructions + input` | `output_text` |

**`SGS_AI_REASONING=none` 是关键开关（默认已是 none）**：Responses 协议的思维链
参数必须写成嵌套的 `{"reasoning": {"effort": "none"}}`——传 `"low"` 不被识别
（退回默认 high），传顶层 `reasoning_effort` 完全无效。实测 hy3：开着思维链
单次 12.7 秒，关掉 1.4 秒，一局从一小时变成几分钟。

## 11. 本机代理（`tools/ai_proxy.py`）

零依赖（标准库 `http.server` + `urllib`）的明文转发器：

```text
游戏进程 ──明文 HTTP──► 127.0.0.1:8899 ──HTTPS(TLS)──► 真实 LLM 接口
                        （key 只配在代理进程）
```

- **密钥不进游戏进程**：游戏只跟回环地址通信，不需要知道 API key；
- 只监听 127.0.0.1；`GET /health` 健康检查；`ThreadingHTTPServer` 并发
  （单线程版会把第二个请求堵住）；上游 4xx/5xx 错误体原样带回，游戏侧能看到真实原因；
- `-v` 打印每次完整请求/响应，是排查提示词/输出问题的第一现场。

## 12. 两个接入点

### 12.1 单机（`src/ui/scene_room.lua`）

- 菜单「AI 托管」三档：`off` / `others`（其他座位）/ `all`（全部）；
- 进牌桌后按**数字键 1..N** 把任意座位在「AI 托管 ↔ 原控制者」间随时切换
  （想让 AI 替你打一手就按自己座位的数字）；
- **Agent 始终创建**（传输层可为空——空 = 永远机械兜底，游戏照样能玩不会卡死），
  所以牌桌上随时切座位给 AI 不用重开；
- UI 每帧 `driver:advance()`，返回 `"thinking"` 就什么都不做下一帧再问，
  同时用 `agent:thinkingLabel()` 显示「P2 正在思考：是否发动【反馈】（第 2 次尝试）…」；
- 时钟用 `love.timer.getTime`（os.time 只有秒级精度，超时判断会差一整秒）。

### 12.2 联机（`src/net/server.lua` + `src/net/host.lua`）

- 服务端设 `SGS_NET_AI=1`（或 `on`/`all` = 全部空座；`"2,3"` = 指定座位）后，
  空座由 `p:setControl("ai")` 交给 LLM（**人来了人优先**）；不设或 `off`/`0`
  就是原来的规则 BOT；
- 与单机共用同一套 `SGS_AI_*` 环境变量与传输层选择；优先用 love.thread 线程版
  （不阻塞服务端 tick），无 love 环境时退回 core 同步实现（仅建议测试用）；
- 空座 AI 的决策在服务端完成，人类客户端只收到结算结果。

## 13. 配置速查（环境变量）

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `SGS_AI_TRANSPORT` | `proxy`（走本机代理，推荐）/ `curl`（直连 HTTPS） | `curl` |
| `SGS_AI_URL` | 模型接口地址（curl 模式必填；也是代理的上游） | — |
| `SGS_AI_KEY` | 接口密钥（curl 模式必填；识别 `OPENAI_API_KEY`） | — |
| `SGS_AI_MODEL` | 模型名 | `hy3` |
| `SGS_AI_REASONING` | Responses 思维链强度，**必须 `none`**（见 §10） | `none` |
| `SGS_AI_PROTOCOL` | `chat` / `responses` | 按 URL 猜 |
| `SGS_AI_PROXY` | 代理地址（proxy 模式） | `http://127.0.0.1:8899` |
| `SGS_NET_AI` | 联机空座是否交给 LLM（`1`/`on`/`all`/`"2,3"`/`off`） | 关（规则 BOT） |

什么都不配也能玩：Agent 没有传输层 → 每次询问直接机械兜底
（不出牌、不响应、必答题机械给），**被动且安全，不会卡死**。

## 14. 调试与验证工具

| 工具 | 用途 |
| --- | --- |
| `./tools/lua.sh tools/ai-check.lua` | AI 自检：配置 → 连通 → 延迟 → 决策格式，一条命令出结论 |
| `./tools/lua.sh tools/ai-demo.lua` | 真机跑一局 headless 对局：打印每次决策原文（含理由/身份判断/长期观察）+ 结束时统计「询问 N 次，模型成功 X，重试 Y，机械兜底 Z（规则 BOT 已不参与）」 |
| `tests/test_ai.lua`（107 项） | 枚举/观察/记忆/提示词/解析/Agent/传输层的全量单测，Mock 传输层跑通异步路径 |
| `./tools/ai_proxy.py -v` | 看每次请求/响应全文 |

## 15. 设计取舍小结

| 决策 | 理由 |
| --- | --- |
| 只在枚举候选里选编号 | 结构上杜绝非法动作；提示词短、解析稳；规则判断与人类/BOT 同源 |
| 所有请求都问 LLM（含出闪/出桃） | 完全自主；高频响应延迟靠关思维链（1.4s/次）压下来 |
| 兜底不回落规则 BOT | 避免 AI 的 bug 被伪装成「打得像 BOT」；错误回喂让模型自纠 |
| 出牌/响应兜底为被动放弃 | 失联时乱出牌比不出牌危险；必答题才机械执行 |
| 观察层信息隐藏 | 反开图作弊；身份判断必须是推理出来的 |
| 跨步骤记忆 | 身份推理需要积累：怀疑 → 观察 → 修正，单次问答做不到 |
| curl/代理 + 后台线程 | LuaSocket 无 TLS；1~3s 网络往返不能阻塞主线程/服务端 tick |
| 密钥不进命令行、proxy 模式不进游戏进程 | `ps aux` 可见命令行；泄露面差一个量级 |
