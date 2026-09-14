-- AI 响应源：与 BOT 并列的第三种「回答请求的人」
--
-- 用法：把它挂到 Driver 上（见 src/core/driver.lua），凡是 controller="ai"
-- 的座位，请求就会转到这里来决策。
--
-- 形态是**异步状态机**，不是一次调用出结果：
--   第一次被问到某个请求 → 构造观察/候选/提示词 → 提交给传输层 → 返回 "thinking"
--   后续再被问同一个请求 → 轮询结果；没好继续 "thinking"，好了就解析并 "ready"
-- 这样上层（UI 每帧 driver:advance()）不用改结构，也不会被网络卡住。
--
-- **降级是设计的一部分，不是兜底补丁**：超时、解析失败、动作非法、
-- 没配 API key……任何一条都会静默回落到规则 BOT。理由很简单——
-- 联网的东西一定会失败，而游戏一次都不能卡死。
local class = require "src.class"
local Actions = require "src.core.ai.actions"
local Prompt = require "src.core.ai.prompt"
local Parse = require "src.core.ai.parse"
local Bot = require "src.core.bot"

local Agent = class("Agent")

function Agent:init(opts)
  opts = opts or {}
  self.transport = opts.transport
  self.fallback = opts.fallback or Bot.make()
  self.timeout = opts.timeout or 20               -- 秒
  self.clock = opts.clock or os.time              -- 可注入，UI 侧给 love.timer.getTime
  self.ask_all = opts.ask_all == true             -- 连「出闪/出桃」也问 LLM（会很慢）
  self.on_decision = opts.on_decision             -- 决策回调：调试/观战 UI 用
  self.on_error = opts.on_error
  self.current = nil
  self.stats = { asked = 0, by_ai = 0, by_fallback = 0, errors = {} }
end

-- ===== 对外：回答一个请求 =====
-- 返回 (响应, "ready") 或 (nil, "thinking")
function Agent:respond(req, room)
  if not self.transport then
    return self:useFallback(req, room, "未配置传输层"), "ready"
  end
  if not Actions.worthAsking(req, { all_requests = self.ask_all }) then
    -- 响应牌（闪/桃/无懈）默认走规则：一次 LLM 往返 1~3 秒，
    -- 每次被杀都卡一下，对局观感会非常糟糕
    return self:useFallback(req, room, "该请求类型不询问 LLM"), "ready"
  end

  local cur = self.current
  if not (cur and cur.req == req) then
    return self:_start(req, room)
  end
  return self:_poll(req, room)
end

function Agent:_start(req, room)
  local actions = Actions.enumerate(req, room)
  if #actions == 0 then
    return self:useFallback(req, room, "没有可行动作"), "ready"
  end
  local prompt = Prompt.build(room, req, actions, {})
  self.stats.asked = self.stats.asked + 1
  local ok = self.transport:submit(prompt)
  if not ok then
    return self:useFallback(req, room, "提交请求失败"), "ready"
  end
  self.current = {
    req = req, actions = actions, prompt = prompt,
    started = self.clock(),
  }
  return nil, "thinking"
end

function Agent:_poll(req, room)
  local cur = self.current
  if not cur then return self:useFallback(req, room, "状态丢失"), "ready" end

  if self.clock() - cur.started > self.timeout then
    if self.transport.cancel then self.transport:cancel() end
    return self:useFallback(req, room, string.format("超过 %d 秒未返回", self.timeout)), "ready"
  end

  local res = self.transport:poll()
  if not res then return nil, "thinking" end
  if not res.ok then
    return self:useFallback(req, room, res.err or "调用失败"), "ready"
  end

  local resp, err = Parse.response(res.text, req, room, cur.actions)
  if err then
    return self:useFallback(req, room, err), "ready"
  end

  self.stats.by_ai = self.stats.by_ai + 1
  if self.on_decision then
    pcall(self.on_decision, {
      req = req, room = room, raw = res.text,
      prompt = cur.prompt, actions = cur.actions,
    })
  end
  self.current = nil
  return resp, "ready"
end

-- 记录原因并交给规则 BOT。注意 BOT 自己也可能出错，所以包了 pcall。
function Agent:useFallback(req, room, reason)
  self.stats.by_fallback = self.stats.by_fallback + 1
  local errs = self.stats.errors
  errs[#errs + 1] = tostring(reason)
  if #errs > 20 then table.remove(errs, 1) end
  if self.on_error then pcall(self.on_error, reason, req) end
  self.current = nil
  local ok, resp = pcall(self.fallback, req, room)
  if not ok then return nil end
  return resp
end

-- ===== 给 UI 的状态查询 =====

function Agent:isThinking()
  return self.current ~= nil
end

-- 一句「某某正在思考…」，给牌桌上显示用
function Agent:thinkingLabel()
  local cur = self.current
  if not cur then return nil end
  local r = cur.prompt and cur.prompt.view and cur.prompt.view.request
  return string.format("%s 正在思考：%s",
    cur.req.player.name, (r and r.ask) or cur.req.type)
end

return Agent
