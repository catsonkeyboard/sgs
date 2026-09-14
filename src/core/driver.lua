-- 驱动器：把房间的 pending 请求路由给人类 / BOT / AI
-- 这是协程循环与外部世界（UI/网络）之间的唯一桥梁。
--
-- 三种响应源是**并列**关系：
--   human —— 停下来等 UI 点击（UI 每帧调 advance 拿回 "human"）
--   bot   —— 规则驱动的脚本对手，同步出结果
--   ai    —— LLM 驱动，异步；这一轮没结果就返回 "thinking"，下帧再问
-- 新增响应源只需在这里加一个分支，规则引擎一行都不用改。
local class = require "src.class"
local Bot = require "src.core.bot"

local Driver = class("Driver")

-- ai_respond 可以是 Agent 实例（有 respond 方法），也可以是 function(req, room)
function Driver:init(room, bot_respond, ai_respond)
  self.room = room
  self.bot_respond = bot_respond or Bot.make()
  self.ai_respond = ai_respond
end

-- 推进直到：等待人类响应（"human"）、AI 思考中（"thinking"）、游戏结束（"over"）
-- 第二个返回值是卡住时的请求对象，供 UI 显示「谁在想什么」
function Driver:advance()
  while self.room.pending and not self.room.game_over do
    local req = self.room.pending
    local mode = req.player:controlMode()

    if mode == "human" then
      return "human", req
    end

    if mode == "ai" and self.ai_respond then
      local resp, state = self:_askAI(req)
      if state == "thinking" then return "thinking", req end
      self.room:step(resp)
    else
      self.room:step(self.bot_respond(req, self.room))
    end
  end
  return "over"
end

-- AI 自己抛异常也必须能继续：整局卡死在一个网络库的报错上太不值得了，
-- 出错就当这次没问成，回落到规则 BOT。
function Driver:_askAI(req)
  local ok, resp, state = pcall(function()
    if type(self.ai_respond) == "function" then
      return self.ai_respond(req, self.room)
    end
    return self.ai_respond:respond(req, self.room)
  end)
  if ok then return resp, state end
  return self.bot_respond(req, self.room), "ready"
end

return Driver
