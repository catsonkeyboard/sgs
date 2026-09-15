-- AI 响应源：完全由 LLM 决策，规则 BOT 不再参与
--
-- 与上一版的关键差别（上一版是「关键决策问 AI，其余走 BOT」）：
--   1. **所有请求都问 AI**，包括出闪/出桃/无懈可击这类高频响应；
--   2. **兜底不再调用规则 BOT**：LLM 抽风时先重试（把错误反馈给它），
--      仍失败就机械地选第一个合法动作 —— 决策始终不是规则脚本做的；
--   3. **跨步骤记忆**：每个座位一份，记录它走过的每一步与做过的身份判断，
--      每次请求都完整回放，让 AI 能积累推理、修正判断。
--
-- 形态仍是异步状态机：首次被问到 → 组提示词 → 提交 → "thinking"；
-- 之后轮询 → 解析 → "ready"。上层（UI 每帧 advance）不需要改结构。
local class = require "src.class"
local Actions = require "src.core.ai.actions"
local Prompt = require "src.core.ai.prompt"
local Parse = require "src.core.ai.parse"
local Memory = require "src.core.ai.memory"
local Card = require "src.core.card"

local Agent = class("Agent")

-- 请求类型 → 给人看的短标签（记忆里用）
local STAGE_ZH = {
  askForUseCard = "出牌",
  askForCard = "响应",
  askForSkillInvoke = "技能",
  askForDiscard = "弃牌",
  askForChooseCard = "选牌",
  askForDiscardFrom = "拆牌",
  askForChoice = "选择",
  askForGuanxing = "观星",
}

-- 把 "2" / "P2" / "座位2" / "曹操" 统一解析成玩家名，供身份判断落库
local function makeNameOf(room)
  return function(key)
    local k = tostring(key)
    local n = k:match("^%d+$") or k:match("^[Pp](%d+)$") or k:match("座位(%d+)")
    if n then
      for _, p in ipairs(room.players) do
        if p.seat == tonumber(n) then return p.name end
      end
      return nil
    end
    for _, p in ipairs(room.players) do
      if p.name == k then return p.name end
    end
    return nil
  end
end

local function playerBySeat(room, seat)
  for _, p in ipairs(room.players) do
    if p.seat == seat then return p end
  end
  return nil
end

function Agent:init(opts)
  opts = opts or {}
  self.transport = opts.transport
  -- 全部请求都交给 LLM。设 false 可退回「只问决策类请求」的省流模式。
  self.ask_all = opts.ask_all ~= false
  -- 兜底策略，默认 "retry"（重试 + 机械选择），**不会调用规则 BOT**。
  -- 传 "bot" 才会启用旧行为，留给对比测试。
  self.fallback = opts.fallback or "retry"
  self.retries = opts.retries or 1
  self.timeout = opts.timeout or 30
  self.clock = opts.clock or os.time
  self.memory_on = opts.memory ~= false
  self.max_steps = opts.max_steps or 60
  self.on_decision = opts.on_decision
  self.on_error = opts.on_error
  self.current = nil
  self.memories = {}   -- seat -> Memory
  self.stats = {
    asked = 0, by_ai = 0, retried = 0, mechanical = 0,
    timeouts = 0, errors = {}, rejections = {},
  }
end

function Agent:memoryFor(player)
  if not self.memory_on then return nil end
  local key = player.seat or player.name
  if not self.memories[key] then
    self.memories[key] = Memory.create({ seat = player.seat, max_steps = self.max_steps })
  end
  return self.memories[key]
end

-- ===== 对外：回答一个请求 =====
-- 返回 (响应, "ready") 或 (nil, "thinking")
--
-- 整体包一层 pcall：只要 AI 这一层不往外抛异常，Driver 里那条
-- 「AI 出错就用规则 BOT」的保险就永远不会触发（见 driver.lua 的 _askAI）。
-- 这是「规则 BOT 退出决策路径」的最后一块拼图——异常路径上也没有 BOT。
function Agent:respond(req, room)
  local ok, resp, state = pcall(function()
    return self:_respond(req, room)
  end)
  if ok then return resp, state end
  return self:_mechanical(req, room, "内部异常：" .. tostring(resp)), "ready"
end

function Agent:_respond(req, room)
  if not self.transport then
    return self:_mechanical(req, room, "未配置传输层"), "ready"
  end
  if not Actions.worthAsking(req, { all_requests = self.ask_all }) then
    return self:_mechanical(req, room, "该请求类型未开启 LLM"), "ready"
  end

  local cur = self.current
  if not (cur and cur.req == req) then
    return self:_start(req, room)
  end
  return self:_poll(req, room)
end

function Agent:_buildPrompt(req, room, actions, memory, hint)
  return Prompt.build(room, req, actions, {
    memory = memory,
    nameOf = makeNameOf(room),
    retry_hint = hint,
  })
end

function Agent:_start(req, room, hint)
  local actions = Actions.enumerate(req, room)
  if #actions == 0 then
    -- 一个候选都没有：不是 LLM 的问题，直接机械应答（通常是「结束出牌」）
    return self:_mechanical(req, room, "没有可行动作"), "ready"
  end
  local memory = self:memoryFor(req.player)
  local prompt = self:_buildPrompt(req, room, actions, memory, hint)
  self.stats.asked = self.stats.asked + 1
  if not self.transport:submit(prompt) then
    return self:_retryOrMechanical(req, room, "提交请求失败")
  end
  self.current = {
    req = req, actions = actions, prompt = prompt,
    memory = memory, attempt = 1, started = self.clock(),
  }
  return nil, "thinking"
end

function Agent:_poll(req, room)
  local cur = self.current
  if not cur then return self:_mechanical(req, room, "状态丢失"), "ready" end

  if self.clock() - cur.started > self.timeout then
    self.stats.timeouts = self.stats.timeouts + 1
    if self.transport.cancel then self.transport:cancel() end
    return self:_retryOrMechanical(req, room,
      string.format("超过 %d 秒未返回", self.timeout))
  end

  local res = self.transport:poll()
  if not res then return nil, "thinking" end
  if not res.ok then
    return self:_retryOrMechanical(req, room, res.err or "调用失败")
  end

  local resp, err, extra = Parse.response(res.text, req, room, cur.actions)
  if err then
    self.stats.rejections[#self.stats.rejections + 1] = err
    if #self.stats.rejections > 20 then table.remove(self.stats.rejections, 1) end
    return self:_retryOrMechanical(req, room, err)
  end

  self.stats.by_ai = self.stats.by_ai + 1
  self:_remember(req, room, cur, resp, extra)
  if self.on_decision then
    pcall(self.on_decision, {
      req = req, room = room, raw = res.text, resp = resp, extra = extra,
      prompt = cur.prompt, actions = cur.actions, memory = cur.memory,
    })
  end
  self.current = nil
  return resp, "ready"
end

-- 重试：把上一次的失败原因回喂给模型，让它自己纠正。
function Agent:_retryOrMechanical(req, room, reason)
  local cur = self.current
  local attempt = cur and cur.attempt or 1
  self.stats.errors[#self.stats.errors + 1] = tostring(reason)
  if #self.stats.errors > 30 then table.remove(self.stats.errors, 1) end
  if self.on_error then pcall(self.on_error, reason, req) end
  if cur then cur.attempt = attempt + 1 end

  if cur and attempt <= self.retries then
    self.stats.retried = self.stats.retried + 1
    local prompt = self:_buildPrompt(req, room, cur.actions, cur.memory,
      string.format("你上一次的输出无法使用（%s）。请只输出符合格式的一行 JSON，"
        .. "action 必须是后面列出的编号之一。", tostring(reason)))
    if self.transport:submit(prompt) then
      cur.prompt = prompt
      cur.started = self.clock()
      return nil, "thinking"
    end
  end

  self.current = nil
  return self:_mechanical(req, room, reason), "ready"
end

-- 机械兜底：**不调用规则 BOT**。
--
-- 为什么是「被动」而不是「选第一个合法动作」：模型失联时，
-- 「乱出一张牌」比「什么都不做」危险得多——前者可能把桃/无懈可击
-- 在错误时机打出去，后者最多就是这一手没动作。所以：
--   - 出牌/响应（askForUseCard / askForCard）→ 被动放弃（nil）
--   - 技能征询 → 不发动
--   - 必须给牌/选牌的（弃牌/五谷/拆牌/选项）→ 机械执行，否则会违规卡死
function Agent:_mechanical(req, room, reason)
  self.stats.mechanical = self.stats.mechanical + 1
  -- current 可能是上一个请求遗留的（比如 transport 失效时），
  -- 只在与当前请求匹配时才复用它的候选，否则重新枚举
  local actions
  if self.current and self.current.req == req then
    actions = self.current.actions
  else
    actions = Actions.enumerate(req, room)
  end

  if req.type == "askForSkillInvoke" then return false end
  if req.type == "askForGuanxing" then return nil end -- 观星：nil = 保持原序（引擎约定）
  if req.type == "askForDiscard" then
    -- any 模式（制衡类自选）：机械兑底选**不弃**（空表）——最安全
    if req.any then return {} end
    local out = {}
    for _, a in ipairs(actions) do
      if a.kind == "discard" and #out < (req.n or 0) then out[#out + 1] = a.card end
    end
    return out
  end
  if req.type == "askForChooseCard" or req.type == "askForDiscardFrom" then
    for _, a in ipairs(actions) do
      if a.kind == "choose" then return a.card end
    end
    return nil
  end
  if req.type == "askForChoice" then
    for _, a in ipairs(actions) do
      if a.kind == "choice" then return a.value end
    end
    return nil
  end
  return nil   -- askForUseCard / askForCard：被动放弃，不乱出牌
end

-- ===== 记忆 =====

local function describeChoice(req, resp)
  if req.type == "askForUseCard" then
    if resp == nil then return "结束出牌" end
    local t = resp.target
    if t == req.player then return string.format("使用【%s】", resp.card:zhName()) end
    return string.format("使用【%s】→%s", resp.card:zhName(), t and t.name or "?")
  elseif req.type == "askForCard" then
    if resp == nil then
      return string.format("不打出【%s】", Card.ZH[req.card_name] or req.card_name)
    end
    return string.format("打出【%s】", resp:zhName())
  elseif req.type == "askForSkillInvoke" then
    return resp and string.format("发动【%s】", tostring(req.skill))
      or string.format("不发动【%s】", tostring(req.skill))
  elseif req.type == "askForDiscard" then
    local names = {}
    for _, c in ipairs(resp or {}) do names[#names + 1] = c:zhName() end
    return "弃置 " .. (#names > 0 and table.concat(names, "") or "无")
  elseif req.type == "askForDiscardFrom" then
    return resp and ("弃掉 " .. resp:zhName()) or "未弃牌"
  elseif req.type == "askForChooseCard" then
    return resp and ("拿了 " .. resp:zhName()) or "没拿"
  elseif req.type == "askForChoice" then
    return tostring(resp)
  elseif req.type == "askForGuanxing" then
    if resp == nil then return "观星：保持原序" end
    local top = {}
    for i = #(resp.up or {}), 1, -1 do top[#top + 1] = resp.up[i]:zhName() end
    return "观星重排：顶=" .. (#top > 0 and table.concat(top, "") or "无")
      .. string.format("（%d 张沉底）", #(resp.down or {}))
  end
  return "（已响应）"
end

function Agent:_remember(req, room, cur, resp, extra)
  local mem = cur.memory
  if not mem then return end
  mem:record({
    turn = room.turn_count,
    stage = STAGE_ZH[req.type] or req.type,
    choice = describeChoice(req, resp),
    reason = (extra and extra.reason) or "",
  })
  if extra and extra.beliefs then
    mem:updateBeliefs(extra.beliefs, makeNameOf(room))
  end
  if extra and extra.note then mem:setNotes(extra.note) end
end

-- ===== 给 UI 的状态查询 =====

function Agent:isThinking()
  return self.current ~= nil
end

function Agent:thinkingLabel()
  local cur = self.current
  if not cur then return nil end
  local r = cur.prompt and cur.prompt.view and cur.prompt.view.request
  local base = string.format("%s 正在思考：%s",
    cur.req.player.name, (r and r.ask) or cur.req.type)
  if cur.attempt and cur.attempt > 1 then
    return base .. string.format("（第 %d 次尝试）", cur.attempt)
  end
  return base
end

Agent.STAGE_ZH = STAGE_ZH

return Agent
