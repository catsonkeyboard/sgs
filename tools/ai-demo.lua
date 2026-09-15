-- AI 真机验证：用真实 LLM 跑一局 headless 对局，打印决策与降级统计
--
-- 用法（从项目根目录）：
--
--   方式一，走本机代理（推荐）：
--     export SGS_AI_URL="https://llm.example.com/v1/responses"
--     export SGS_AI_KEY="sk-..."
--     ./tools/ai_proxy.py &              # 另开一个终端，或加 & 放后台
--     export SGS_AI_TRANSPORT=proxy
--     ./tools/lua.sh tools/ai-demo.lua
--
--   方式二，直连 HTTPS：
--     export SGS_AI_URL="..." SGS_AI_KEY="..."
--     ./tools/lua.sh tools/ai-demo.lua
--
-- 说明：
--   - 这里用的是**同步**传输层（headless 没有主线程可阻塞，无所谓），
--     图形界面里走的是 src/ui/ai_transport.lua 的线程版。
--   - 一局大约几十次请求，小模型跑完通常几分钟。中途 Ctrl-C 无副作用。
--   - 没配环境变量时会直接提示，不会假装成功。
package.path = "./?.lua;" .. package.path

local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local Bot = require "src.core.bot"
local Agent = require "src.core.ai.agent"
local Transport = require "src.core.ai.transport"

local model = os.getenv("SGS_AI_MODEL") or "hy3"
local mode = os.getenv("SGS_AI_TRANSPORT") or "curl"
local url, key = os.getenv("SGS_AI_URL"), os.getenv("SGS_AI_KEY")
local protocol = os.getenv("SGS_AI_PROTOCOL")
local effort = os.getenv("SGS_AI_REASONING") or "none"
local transport = nil

if mode == "proxy" then
  local base = os.getenv("SGS_AI_PROXY") or "http://127.0.0.1:8899"
  protocol = protocol or "responses"
  local path = (protocol == "responses") and "/v1/responses" or "/v1/chat/completions"
  transport = Transport.proxy {
    url = base, path = path, protocol = protocol, model = model,
    reasoning_effort = effort, timeout = 90,
  }
  local alive, code = transport:health()
  if not alive then
    print(string.format("代理 %s 没起（health 返回 %s）。", base, tostring(code)))
    print("先跑：./tools/ai_proxy.py &")
    return
  end
  print("代理模式：游戏侧不需要密钥")
else
  if not url or url == "" or not key or key == "" then
    print("未配置 SGS_AI_URL / SGS_AI_KEY，无法做真机验证。")
    print("示例：export SGS_AI_URL=https://llm.example.com/v1/responses")
    print("             export SGS_AI_KEY=sk-xxx ; export SGS_AI_MODEL=hy3")
    return
  end
  transport = Transport.curl {
    url = url, api_key = key, model = model,
    protocol = protocol, reasoning_effort = effort, timeout = 60,
  }
end
print(string.format("模型 %s 协议 %s 思维链 %s", model,
  transport.protocol or "?", effort))
local SEATS = 5
local AI_SEATS = { 1, 3 }

local engine = Engine.create()
Standard.setup(engine)
local pool = { "刘备", "曹操", "孙权", "貂蝉", "吕布" }
local ps = {}
for i = 1, SEATS do
  local g = engine:getGeneral(pool[i]) or engine:getGeneral("白板武将")
  table.insert(ps, Player.create("P" .. i, g, i, false))
end
for _, s in ipairs(AI_SEATS) do ps[s]:setControl("ai") end

local room = Room.create(engine, ps)
room.drawPile = Standard.buildDrawPile(2026)
room.rng = Standard.makeRng(2026)
room:setupRoles(Standard.makeRng(2027))
room:start()

-- 打印每一次 AI 的真实输出，方便判断模型到底在想什么（慢，但值得看）
local agent = Agent.create({
  transport = transport,
  timeout = 90,
  on_decision = function(d)
    local r = d.prompt and d.prompt.view and d.prompt.view.request
    print(string.format("[AI] %s | %s | %s", d.req.player.name,
      (r and r.ask) or d.req.type, tostring(d.raw):gsub("\n", " ")))
  end,
  on_error = function(reason, req)
    print(string.format("[回落] %s | %s | %s", req.player.name, req.type, tostring(reason)))
  end,
})

print(string.format("模型 %s，%d 人局，AI 座位 %s", model, SEATS, table.concat(AI_SEATS, ",")))
print("开始对局…\n")

local driver = Driver.create(room, Bot.make(), agent)
local guard = 0
while not room.game_over and guard < 200000 do
  guard = guard + 1
  local state, req = driver:advance()
  if state == "over" then break end
  if state == "thinking" then
    local resp, st = agent:respond(req, room)
    if st == "ready" then room:step(resp) end
  elseif state == "human" then
    room:step(Bot.make()(req, room))
  end
end

local total = #room.drawPile + #room.discardPile
for _, p in ipairs(room.players) do total = total + p:allCardCount() end

print(string.format("\n对局结束：%d 轮，胜者 %s，卡牌守恒 %d/%d",
  room.turn_count,
  room.winner and room.winner.name or (room.win_role or "平局"),
  total, Standard.deckSize()))
print(string.format("AI 询问 %d 次，模型成功 %d 次，重试 %d 次，机械兜底 %d 次（规则 BOT 已不参与）",
  agent.stats.asked, agent.stats.by_ai, agent.stats.retried, agent.stats.mechanical))
if #agent.stats.errors > 0 then
  print("失败原因（最近 10 条）：")
  for i = math.max(1, #agent.stats.errors - 9), #agent.stats.errors do
    print("  - " .. agent.stats.errors[i])
  end
end
-- 每个 AI 座位最后记得了什么：身份判断是最值得看的
for seat, mem in pairs(agent.memories) do
  print(string.format("\n=== 座位 %s 的记忆（%d 步）===", tostring(seat), mem.total))
  local _, b = next(mem.beliefs)
  if b then
    for name, label in pairs(mem.beliefs) do
      print(string.format("  判断 %s 是：%s", name, label))
    end
  else
    print("  （没给出身份判断）")
  end
end
