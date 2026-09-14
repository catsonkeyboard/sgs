-- 客户端：连上服务端、收消息、应答请求
--
-- 与 Host 一样只认通道，所以既能走真实 TCP，也能在测试里走内存通道。
local class = require "src.class"
local Protocol = require "src.net.protocol"
local Channel = require "src.net.channel"

local Client = class("Client")

function Client:init(name, channel)
  self.name = name
  self.channel = channel
  self.seat = nil
  self.state = nil
  self.logs = {}
  self.requests = {}  -- 收到的待应答请求（id -> msg）
  self.over = nil
  self.chats = {}
  self.token = nil      -- 重连令牌（welcome 下发）
  self.spectating = false
  self.on_request = nil -- 可选回调：function(client, req_msg) -> 应答表
end

-- hello / 观战：观战必须在 hello 时说明，服务端据此不分配座位。
-- （这里原本还有一份无参数的 Client:hello，被下面这份覆盖成了死代码，已删除。）
function Client:hello(spectate)
  self.channel:send { type = "hello", name = self.name, spectate = spectate and true or nil }
end

function Client:ready(v)
  self.channel:send { type = "ready", ready = (v ~= false) }
end

-- 聊天
function Client:chat(text)
  self.channel:send { type = "chat", text = text }
end

-- 重连：用 welcome 下发的令牌坐回原座
function Client:resume(token)
  self.channel:send { type = "resume", token = token }
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
    if msg.token then self.token = msg.token end
    if msg.resumed then self.resumed = true end
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
  elseif t == "chat" then
    table.insert(self.chats, msg)
  elseif t == "spectating" then
    self.spectating = true
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

-- 连到服务端（真实 TCP）。注意：连接能力放在 Channel 上，不要在 Client 上
-- 定义名为 connect 的方法 —— 会与 socket 的 sock:connect 在静态检查里撞名。
function Client.connectTo(name, host, port)
  local ch, err = Channel.open(host, port)
  if not ch then return nil, err end
  return Client.create(name, ch)
end

-- 控制台客户端：连上、ready、自动应答请求。
-- auto 为应答策略：function(req_msg) -> value，默认一律 false（不发动/不出牌）
function Client.consoleMain(name, host, port, auto, spectate)
  local socket = require "socket"
  -- 管道/重定向时 stdout 是块缓冲，日志会迟迟不出现；改成行缓冲
  pcall(function() io.stdout:setvbuf("line") end)
  local c, err = Client.connectTo(name, host, port)
  if not c then
    print("[客户端] 连接失败: " .. tostring(err))
    return false
  end
  print(string.format("[客户端] 已连接 %s:%d（名字 %s）", host or "?", port or 0, name))
  c:hello(spectate)
  if not spectate then c:ready(true) end
  auto = auto or function() return false end
  c.on_request = function(_self, req) return auto(req) end

  local seen = 0
  local seen_chat = 0
  local guard = 0
  while not c.over and guard < 200000 do
    guard = guard + 1
    c:flush()
    -- 打印新日志
    while seen < #c.logs do
      seen = seen + 1
      print("  | " .. c.logs[seen])
    end
    while seen_chat < #c.chats do
      seen_chat = seen_chat + 1
      local m = c.chats[seen_chat]
      print(string.format("  [%s] %s", tostring(m.name), tostring(m.text)))
    end
    if c.over then break end
    socket.sleep(0.02)
  end
  if c.over then
    print(string.format("[客户端] 对局结束，胜者=%s", tostring(c.over.winner)))
  else
    print("[客户端] 超时退出")
  end
  return true
end

return Client
