-- 客户端：连上服务端、收消息、应答请求
--
-- 与 Host 一样只认通道，所以既能走真实 TCP，也能在测试里走内存通道。
local class = require "src.class"
local Protocol = require "src.net.protocol"

local Client = class("Client")

function Client:init(name, channel)
  self.name = name
  self.channel = channel
  self.seat = nil
  self.state = nil
  self.logs = {}
  self.requests = {}  -- 收到的待应答请求（id -> msg）
  self.over = nil
  self.on_request = nil -- 可选回调：function(client, req_msg) -> 应答表
end

function Client:hello()
  self.channel:send { type = "hello", name = self.name }
end

function Client:ready(v)
  self.channel:send { type = "ready", ready = (v ~= false) }
end

-- 应答某个请求
function Client:respond(id, value)
  self.channel:send { type = "resp", id = id, value = value }
  self.requests[id] = nil
end

-- 收取并处理一条消息；返回该消息（或 nil）
function Client:poll()
  local msg = self.channel:recv()
  if not msg then return nil end
  local t = msg.type
  if t == "welcome" then
    self.seat = msg.seat
  elseif t == "seats" then
    self.seats = msg.seats
  elseif t == "start" then
    self.started = true
  elseif t == "log" then
    for _, l in ipairs(msg.lines or {}) do table.insert(self.logs, l) end
  elseif t == "state" then
    self.state = msg.snapshot
  elseif t == "req" then
    self.requests[msg.id] = msg
    if self.on_request then
      local ans = self.on_request(self, msg)
      if ans ~= nil then self:respond(msg.id, ans) end
    end
  elseif t == "over" then
    self.over = msg
  end
  return msg
end

-- 收空当前所有待处理消息
function Client:flush(n)
  local got = 0
  for _ = 1, (n or 100) do
    if not self:poll() then break end
    got = got + 1
  end
  return got
end

return Client
