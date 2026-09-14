-- 服务端：LuaSocket TCP，把真实连接适配成 Host 需要的通道
--
-- 用法：./tools/serve.sh [端口] [座位数]
--
-- 流程：监听 → 客户端接入占座 → 全员 ready 后开局 → 驱动 Host:tick()
--       → 广播 log / state / over。空座由 BOT 顶替，所以 1 人也能开局试玩。
--
-- TCP 通道的实现在 src/net/channel.lua（与客户端共用）。
local class = require "src.class"
local socket = require "socket"
local Channel = require "src.net.channel"
local Host = require "src.net.host"

local Server = class("Server")

-- 监听地址：默认 0.0.0.0（IPv4）。不要写 "*" —— LuaSocket 3.0 在 macOS 上
-- 可能解析成 IPv6，导致客户端连 127.0.0.1 直接失败（实测踩过）。
local HOST = nil

function Server:init(port, count)
  self.port = port or 9527
  self.host = Host.create { count = count or 5 }
  self.clients = {} -- channel -> seat
  self.finished = false
end

function Server:bind()
  self.sock = assert(socket.tcp())
  self.sock:setoption("reuseaddr", true)
  local ok, err = self.sock:bind(HOST or "0.0.0.0", self.port)
  if not ok then
    -- 退一步绑回环，至少本机可联调
    ok, err = self.sock:bind("127.0.0.1", self.port)
    assert(ok, "绑定端口失败: " .. tostring(err))
  end
  self.sock:listen(8)
  self.sock:settimeout(0)
  print(string.format("[服务端] 监听 %d，座位数 %d", self.port, self.host.count))
  return true
end

function Server:acceptAll()
  while true do
    local c = self.sock:accept()
    if not c then break end
    local ch = Channel.wrap(c)
    local seat, err = self.host:attach(nil, ch)
    if not seat then
      ch:send { type = "error", message = err or "房间已满" }
      ch:close()
    else
      self.clients[ch] = seat
      ch:send {
        type = "welcome", seat = seat, count = self.host.count,
        seats = self.host:seatInfo(),
      }
      self.host:broadcast { type = "seats", seats = self.host:seatInfo() }
      print(string.format("[服务端] 座位 %d 接入", seat))
    end
  end
end

-- 收取各客户端消息；resp 暂存到 pending，等 Host:tick 来取
function Server:drain()
  for ch, seat in pairs(self.clients) do
    if ch:isClosed() then
      print(string.format("[服务端] 座位 %d 断开", seat))
      self.host:detach(seat)
      self.clients[ch] = nil
    else
      local msg = ch:recv()
      while msg do
        local t = msg.type
        if t == "hello" then
          local s = self.host.seats[seat]
          if s then s.name = msg.name or s.name end
        elseif t == "ready" then
          local s = self.host.seats[seat]
          if s then s.ready = msg.ready ~= false end
          self.host:broadcast { type = "seats", seats = self.host:seatInfo() }
          print(string.format("[服务端] 座位 %d ready=%s", seat, tostring(s and s.ready)))
        elseif t == "resp" then
          ch.pending = ch.pending or {}
          table.insert(ch.pending, msg)
        end
        msg = ch:recv()
      end
    end
  end
end

function Server:pump()
  self:acceptAll()
  self:drain()

  if not self.host.room then
    if self.host:canStart() then
      local seed = os.time() % 2147483647
      self.host:startGame(seed)
      self.host:broadcast { type = "start", seed = seed }
      print("[服务端] 开局，seed=" .. seed)
    end
    return
  end

  if self.host:tick() == "over" then
    self.finished = true
    print("[服务端] 对局结束，胜者="
      .. tostring(self.host.room.winner and self.host.room.winner.name))
  end
end

function Server.run(port, count)
  -- 管道/重定向时 stdout 是块缓冲，日志会迟迟不出现；改成行缓冲
  pcall(function() io.stdout:setvbuf("line") end)
  local srv = Server.create(port, count)
  srv:bind()
  while not srv.finished do
    srv:pump()
    socket.sleep(0.02)
  end
  print("[服务端] 退出")
end

return Server
