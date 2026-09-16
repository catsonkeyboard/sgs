# AI 玩家启动指南

本项目的 AI 托管由 LLM 驱动，模型名通过 **`SGS_AI_MODEL` 显式指定**（不写死默认——接口之间的模型名不通用）。配置位置分两种：

- **直连模式**：必须配在**游戏启动的终端**；
- **代理模式**：配在**跑 ai_proxy.py 的终端**即可（游戏请求不带模型名时由代理注入），游戏侧配了则优先生效。
本文是从零开启 AI 的最短路径；设计与实现细节见 `AI-操作方案.md`。

---

## 一、配置模型接口（二选一）

### 方式一：走本机代理（推荐）

游戏只与 127.0.0.1 明文通信，**密钥不进游戏进程**：

```bash
# 终端 1：起代理
export SGS_AI_URL="https://llm.example.com/v1/responses"
export SGS_AI_KEY="sk-..."
export SGS_AI_MODEL="你的模型名"    # 请求体缺 model 时代理自动注入
./tools/ai_proxy.py                 # 默认监听 127.0.0.1:8899，加 -v 看完整请求/响应

# 终端 2：起游戏（接口配置全在终端 1，这里只需要这两个）
export SGS_AI_TRANSPORT=proxy
./run-game.sh
```

### 方式二：直连 HTTPS（更简单）

不用起代理，但密钥会经过游戏进程：

```bash
export SGS_AI_URL="https://llm.example.com/v1/responses"
export SGS_AI_KEY="sk-..."
export SGS_AI_MODEL="你的模型名"      # 必填：按你的接口填
export SGS_AI_REASONING="none"      # ← 关键，见下
./run-game.sh
```

---

## 二、环境变量一览

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `SGS_AI_URL` | 模型接口地址（Responses 协议用 `/v1/responses`） | 无，必填（直连模式） |
| `SGS_AI_KEY` | 接口密钥（也可用 `OPENAI_API_KEY`） | 无，必填（直连模式） |
| `SGS_AI_MODEL` | 模型名（不写死；直连必配游戏侧，代理模式可只配代理侧） | 无 |
| `SGS_AI_TRANSPORT` | `curl`（直连）/ `proxy`（本机代理） | `curl` |
| `SGS_AI_PROXY` | 代理地址（proxy 模式） | `http://127.0.0.1:8899` |
| `SGS_AI_PROTOCOL` | 接口形态 `chat` / `responses` | 按 URL 猜，默认 `responses` |
| `SGS_AI_REASONING` | 思维链强度 `none` / `low` / ...（Responses 协议） | `none` |
| `SGS_AI_THINKING` | chat 协议思维链（GLM 系）：`off` / `on` / `auto`（不发字段） | 跟随 AI 思考档 |

### 两个关键注意点

1. **`SGS_AI_REASONING=none` 必须设**（代码默认值也是它）。hy3 默认开满血
   思维链，实测单次调用 **12.7 秒**；关掉后 **1.4 秒**——一局从一小时变成
   几分钟。参数必须写成 `{"reasoning": {"effort": "none"}}`，传 `"low"`
   不被识别，传顶层 `reasoning_effort` 完全无效（实测踩坑）。
2. **环境变量必须在启动游戏的同一个终端里 export**，否则游戏进程读不到。

---

## 三、在游戏里开启 AI

- **菜单页**：点「AI 托管」按钮循环切换三档：
  - **关**：全部由人和规则 BOT 操作
  - **其他座位**：除你以外的座位交给 LLM 决策
  - **全部**：连你的座位也交给 AI（观战模式）
- **菜单页**：点「AI 思考」按钮循环切换三档（覆盖 `SGS_AI_REASONING`，初值取该环境变量）：
  - **关**：思维链关闭，单次约 1.5 秒（默认，最快）
  - **低**：轻量思维链，单次数秒
  - **高**：满血思维链，单次 12 秒以上——身份推测更细致，慢一点没关系时用
- **牌桌内**：随时按 **数字键 1..N** 切换单个座位（想让 AI 替你打一手就按 1，
  再按切回自己操作）。

### 看 AI 的身份猜测过程

AI 参与对局时，牌桌右侧有常驻「AI 推测」小面板，实时滚动各 AI 座位的
身份判断变化（谁把谁从"未知"改判成"反贼"、理由是什么）；按钮列的
【AI 推测】打开详情弹层，包含三块：

1. **当前判断**：每个 AI 座位此刻对全场身份的判断表
2. **判断过程**：变化时间线（含改判理由；开「AI 思考」后还包含思维链摘要）
3. **AI 长期观察**：AI 自己记下的场况笔记

Esc、点【关闭】或点弹层外区域关闭。

---

## 四、联机对局里用 AI

服务端设 `SGS_NET_AI` 后，**空座改由 LLM 顶替**（而不是规则 BOT）；
`SGS_AI_*` 变量与单机通用：

```bash
export SGS_NET_AI=1          # 1/on/all = 全部空座；"2,3" = 指定座位（人来了人优先）
export SGS_AI_URL="https://llm.example.com/v1/responses"
export SGS_AI_KEY="sk-..."
export SGS_AI_REASONING="none"
./tools/serve.sh
```

---

## 五、自检与排查

```bash
# 配置 / 连通 / 延迟 / 决策格式一次出结论（开局前先跑这个）
./tools/lua.sh tools/ai-check.lua

# 观察 AI 的实际决策过程（含身份判断与长期观察）
./tools/lua.sh tools/ai-demo.lua
```

### 常见问题

- **什么都没配会怎样？** 可以照常玩：AI 退化为**被动兜底**
  （不出牌、不响应，模型失联时最安全），不会卡死对局。
- **AI 一直很慢？** 检查 `SGS_AI_REASONING` 是否为 `none`（见上）。
- **报「Model xxx does not support … Responses API」？** 该模型只支持
  Chat Completions 协议（如 TokenHub 的 glm-5；hy3 走 Responses）。
  - 直连模式：把 `SGS_AI_URL` 换成 `…/v1/chat/completions`（URL 会自动
    按 chat 猜协议）；
  - 代理模式：在**游戏**的终端 `export SGS_AI_PROTOCOL=chat`（注意不是
    代理终端——协议由游戏侧决定，代理会自动跟随对应端点，`SGS_AI_URL`
    不用改），重启游戏。
  chat 协议下「AI 思考」开关会转为 GLM 系的 `thinking.type` 参数
  （关=disabled / 开=enabled）；若网关不认这个字段报未知参数错，
  `export SGS_AI_THINKING=auto` 可改为不发（代价：无法关思维链，单次很慢）。
- **代理模式连不上？** 确认 `./tools/ai_proxy.py` 已启动、端口是 8899
  （或与 `SGS_AI_PROXY` 一致）；代理日志加 `-v` 查看请求明细。
