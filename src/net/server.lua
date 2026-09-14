-- 服务端：LuaSocket TCP，把真实连接适配成 Host 需要的通道
--
-- 用法：./tools/serve.sh [端口]    （等价 love . --serve）
--
-- 目前是**命令行自测版**：监听端口、接受连接、打印收到的消息，
-- 并按 Host 的规则分配座位。客户端可用 telnet/nc 直接连上来手敲 JSON 观察。
local class = require "src.class"
local Protocol = require "src.net.protocol"
local Host = require "src.net.host"

local Server = class("Server")

-- 监听地址：默认 0.0.0.0（IPv4 全网卡）；需要时可用 --host 覆盖
local HOST = nil

-- 把 socket 包装成 Host 认识的通道
local SocketChannel = class("SocketChannel")
function SocketChannel:init(sock)
  self.sock = sock
  self.buf = ""
  self.closed = false
end
function SocketChannel:send(msg)
  if self.closed then return false end
  local ok, err = self.sock:send(Protocol.encode(msg))
  if not ok then self.closed = true end
  return ok ~= nil
end
-- 非阻塞取一条；没收到完整帧返回 nil
function SocketChannel:recv()
  if self.closed then return nil end
  self.sock:settimeout(0)
  while true do
    local msg, rest = Protocol.takeFrame(self.buf)
    if msg then self.buf = rest return msg end
    local part, err = self.sock:receive(4096)
    if not part then
      if err == "timeout" then return nil end
      self.closed = true
      return nil
    end
    self.buf = rest .. part
  end
end
function SocketChannel:close()
  self.closed = true
  pcall(function() self.sock:close() end)
end

function Server:init(port, count)
  self.port = port or 9527
  self.host = Host.create { count = count or 5 }
  self.clients = {} -- channel -> seat
end

function Server:bind()
  local socket = require "socket"
  self.sock = assert(socket.tcp())
  self.sock:setoption("reuseaddr", true)
  -- 不要写 bind("*")：LuaSocket 3.0 在 macOS 上可能解析成 IPv6，
  -- 导致客户端连 127.0.0.1（IPv4）连不上（实测 connect 直接失败）。
  local ok, err = self.sock:bind(HOST or "0.0.0.0", self.port)
  if not ok then
    -- 退一步绑回环地址，至少本机可联调
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
    local ch = SocketChannel.create(c)
    local seat, err = self.host:attach(nil, ch)
    if not seat then
      ch:send { type = "error", message = err or "房间已满" }
      ch:close()
    else
      self.clients[ch] = seat
      ch:send { type = "welcome", seat = seat, seats = self.host:seatInfo(), count = self.host.count }
      self.host:broadcast { type = "seats", seats = self.host:seatInfo() }
      print(string.format("[服务端] 座位 %d 接入", seat))
    end
  end
end

-- 驱动一帧
function Server:pump()
  self:acceptAll()
  -- 处理各客户端消息（hello/ready/resp）
  for ch, seat in pairs(self.clients) do
    local msg = ch:recv()
    while msg do
      if msg.type == "hello" then
        local s = self.host.seats[seat]
        if s then s.name = msg.name or s.name end
      elseif msg.type == "ready" then
        local s = self.host.seats[seat]
        if s then s.ready = msg.ready ~= false end
        self.host:broadcast { type = "seats", seats = self.host:seatInfo() }
      elseif msg.type == "resp" then
        -- 放回通道，交给 Host:tick 消费
        table.insert(ch.inbox or {}, msg)
      end
      msg = ch:recv()
    end
  end
end

-- SocketChannel 需要一个 inbox 来暂存 resp（Host 主动 recv）
-- 这里简单起见：在 recv 之外再开一个 pending 队列
local rawRecv = SocketChannel.recv
function SocketChannel:recv()
  if self.pending and #self.pending > 0 then
    return table.remove(self.pending, 1)
  end
  return rawRecv(self)
end

function Server.main()
  local socket = require "socket"
  print("[服务端] LuaSocket " .. tostring(socket._VERSION))
  local srv = Server.create(tonumber(arg and arg[3]) or 9527, 5)
  srv:bind()
  -- 命令行自测：跑 10 秒接受连接并回显，不开局（开局要等 UI 客户端）
  local deadline = socket.gettime() + 10
  while socket.gettime() < deadline do
    srv:pump()
    socket.sleep(0.05)
  end
  print("[服务端] 自测结束（未开局，需真实客户端接入后由 UI 触发）")
end

return Server
