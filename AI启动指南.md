# AI 玩家启动指南（TokenHub hy3）

本项目的 AI 托管由 LLM 驱动，当前接入 **TokenHub 的 hy3 模型（Responses API）**。
本文是从零开启 AI 的最短路径；设计与实现细节见 `AI-操作方案.md`。

---

## 一、配置模型接口（二选一）

### 方式一：走本机代理（推荐）

游戏只与 127.0.0.1 明文通信，**密钥不进游戏进程**：

```bash
# 终端 1：起代理
export SGS_AI_URL="https://tokenhub.tencentmaas.com/v1/responses"
export SGS_AI_KEY="sk-..."
./tools/ai_proxy.py                 # 默认监听 127.0.0.1:8899，加 -v 看完整请求/响应

# 终端 2：起游戏
export SGS_AI_TRANSPORT=proxy
./run-game.sh
```

### 方式二：直连 HTTPS（更简单）

不用起代理，但密钥会经过游戏进程：

```bash
export SGS_AI_URL="https://tokenhub.tencentmaas.com/v1/responses"
export SGS_AI_KEY="sk-..."
export SGS_AI_MODEL="hy3"
export SGS_AI_REASONING="none"      # ← 关键，见下
./run-game.sh
```

---

## 二、环境变量一览

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `SGS_AI_URL` | 模型接口地址（TokenHub 用 `/v1/responses`） | 无，必填（直连模式） |
| `SGS_AI_KEY` | 接口密钥（也可用 `OPENAI_API_KEY`） | 无，必填（直连模式） |
| `SGS_AI_MODEL` | 模型名 | `hy3` |
| `SGS_AI_TRANSPORT` | `curl`（直连）/ `proxy`（本机代理） | `curl` |
| `SGS_AI_PROXY` | 代理地址（proxy 模式） | `http://127.0.0.1:8899` |
| `SGS_AI_PROTOCOL` | 接口形态 `chat` / `responses` | 按 URL 猜，默认 `responses` |
| `SGS_AI_REASONING` | 思维链强度 `none` / `low` / ... | `none` |

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
- **牌桌内**：随时按 **数字键 1..N** 切换单个座位（想让 AI 替你打一手就按 1，
  再按切回自己操作）。

---

## 四、联机对局里用 AI

服务端设 `SGS_NET_AI` 后，**空座改由 LLM 顶替**（而不是规则 BOT）；
`SGS_AI_*` 变量与单机通用：

```bash
export SGS_NET_AI=1          # 1/on/all = 全部空座；"2,3" = 指定座位（人来了人优先）
export SGS_AI_URL="https://tokenhub.tencentmaas.com/v1/responses"
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
- **代理模式连不上？** 确认 `./tools/ai_proxy.py` 已启动、端口是 8899
  （或与 `SGS_AI_PROXY` 一致）；代理日志加 `-v` 查看请求明细。
