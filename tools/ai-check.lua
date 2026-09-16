-- AI 功能自检：配置 → 连通 → 延迟 → 决策格式，一条命令出结论
--
-- 用法（从项目根目录）：
--   ./tools/lua.sh tools/ai-check.lua
--
-- 检查项：
--   1. 环境变量是否配置（SGS_AI_URL / SGS_AI_KEY / SGS_AI_MODEL / SGS_AI_REASONING）
--   2. 能不能连通（直接 curl / 经本机代理）
--   3. 单次调用耗时（重点：思维链没关会超过 8 秒，直接提示）
--   4. 返回的能不能被解析成合法动作（游戏里最核心的要求）
package.path = "./?.lua;" .. package.path

local Transport = require "src.core.ai.transport"
local Actions = require "src.core.ai.actions"

local fails, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 print("PASS  " .. msg)
  else fails = fails + 1 print("FAIL  " .. msg) end
end

print("== AI 自检 ==")

-- 1. 配置
local url = os.getenv("SGS_AI_URL")
local key = os.getenv("SGS_AI_KEY") or os.getenv("OPENAI_API_KEY")
local model = os.getenv("SGS_AI_MODEL")
local effort = os.getenv("SGS_AI_REASONING") or "none"
local mode = os.getenv("SGS_AI_TRANSPORT") or "curl"

check(url and url ~= "", "SGS_AI_URL 已配置（" .. tostring(url) .. "）")
if mode ~= "proxy" then
  check(key and key ~= "", "SGS_AI_KEY 已配置（curl 模式需要）")
else
  print("PASS  代理模式：游戏侧不需要密钥")
end
if mode == "proxy" then
  if model and model ~= "" then
    check(true, "SGS_AI_MODEL 已配置（游戏侧，优先于代理侧）：" .. model)
  else
    check(true, "代理模式：模型名可由代理侧注入（SGS_AI_MODEL 配在 ai_proxy.py 的终端）")
  end
else
  check(model and model ~= "",
    "SGS_AI_MODEL 已配置（直连模式必须在游戏侧配置）：" .. tostring(model))
end
check(effort == "none",
  "思维链已关闭（SGS_AI_REASONING=" .. effort .. "）——没关的话每次调用 10 秒以上")
print()

-- 2. 连通
local transport
if mode == "proxy" then
  local base = os.getenv("SGS_AI_PROXY") or "http://127.0.0.1:8899"
  local protocol = os.getenv("SGS_AI_PROTOCOL") or "responses"
  local path = (protocol == "responses") and "/v1/responses" or "/v1/chat/completions"
  transport = Transport.proxy {
    url = base, path = path, protocol = protocol, model = model,
    reasoning_effort = effort, timeout = 60,
  }
  local alive = transport:health()
  check(alive, "本机代理可达（" .. base .. "）——先跑 ./tools/ai_proxy.py &")
  if not alive then
    print(string.format("\n自检结束：%d 项通过，%d 项失败（代理没起，后续跳过）", passes, fails))
    return
  end
else
  if not (url and url ~= "" and key and key ~= "") then
    print(string.format("\n自检结束：%d 项通过，%d 项失败（配置不全，后续跳过）", passes, fails))
    return
  end
  transport = Transport.curl {
    url = url, api_key = key, model = model,
    reasoning_effort = effort, timeout = 60,
  }
end

-- 3. 延迟 + 4. 决策格式：发一个真实的三国杀决策请求
local ProbePrompt = {
  system = "你是三国杀玩家，从合法动作里选最优的。只输出一行 JSON：" ..
    "{\"action\": N, \"reason\": \"20字内\"}",
  user = "【现在需要你决定】出牌阶段\n【合法动作】\n  1. 出【杀】→主公（体力 2/5，距离 2）\n"
    .. "  2. 结束出牌\n只输出一行 JSON：{\"action\": <编号>, \"reason\": \"...\"}",
}

local t0 = os.time()
local r = transport:request(ProbePrompt)
local dt = os.time() - t0

check(r.ok, "能连通并拿到响应（" .. dt .. " 秒）")
if r.ok then
  check(dt < 8, string.format("单次调用 %.1f 秒", dt)
    .. (dt >= 8 and " —— 太慢，检查 SGS_AI_REASONING 是否设了 none" or ""))
  check(type(r.text) == "string" and r.text:find("action") ~= nil,
    "返回包含动作决策（实得 " .. tostring(r.text):gsub("\n", " "):sub(1, 70) .. "）")
end

print(string.format("\n自检结束：%d 项通过，%d 项失败", passes, fails))
if fails > 0 then os.exit(1) end
