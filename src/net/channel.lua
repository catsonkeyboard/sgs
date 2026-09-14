-- 通道：Host 与外界的唯一接口。两种实现：
--   memory  —— 内存队列，测试用（完全确定、不占端口）
--   socket  —— LuaSocket TCP，真实联机用
-- 接口只有三个：send(msg) / recv() / close()
local class = require "src.class"
local Protocol = require "src.net.protocol"

local Channel = {}

-- ===== 内存通道 =====
-- 成对的：一端 send，另一端 recv
local MemChannel = class("MemChannel")

function MemChannel:init()
  self.inbox = {}
  self.peer = nil
  self.closed = false
end

function MemChannel:send(msg)
  if self.closed or not self.peer then return false end
  local peer = self.peer
  table.insert(peer.inbox, msg) -- 送进对端收件箱
  return true
end

function MemChannel:recv()
  if #self.inbox == 0 then return nil end
  return table.remove(self.inbox, 1)
end

function MemChannel:close() self.closed = true end

-- 造一对互联的通道（a 的 send 进 b 的收件箱，反之亦然）
function Channel.pair()
  local a, b = MemChannel.create(), MemChannel.create()
  a.peer, b.peer = b, a
  return a, b
end

-- ===== TCP 通道 =====
-- 收发都走 Protocol 的「一行一个 JSON」帧；send 阻塞，recv 非阻塞（没帧返回 nil）。
local SockChannel = class("SockChannel")

function SockChannel:init(sock)
  self.sock = sock
  self.buf = ""
  self.closed = false
  -- 注意：不要设 settimeout(0)。实测在 LuaSocket 3.0 上，非阻塞模式下
  -- receive 会直接返回 timeout，即使缓冲区里已经有数据（双向都不通）。
  -- 改用「很小的阻塞超时 + select 判可读」，既不会卡住，也能真正读到数据。
  sock:settimeout(0.02)
end

function SockChannel:send(msg)
  if self.closed then return false end
  local ok, err = self.sock:send(Protocol.encode(msg))
  if not ok then
    -- send 可能只发出一部分，这里按整帧发送，失败即视为断开
    self.closed = true
    self.last_err = err
    return false
  end
  return true
end

-- 只读 socket，不碰 pending。服务端的 drain 必须用这个：
-- 否则会把 pending 里的 resp 取出来又塞回去，形成死循环（实测踩过）。
function SockChannel:recvRaw()
  if self.closed then return nil end
  while true do
    local msg, rest = Protocol.takeFrame(self.buf)
    if msg then self.buf = rest return msg end
    -- 直接用带小超时的阻塞读即可（实测 select + 非阻塞组合在 LuaSocket 3.0 上
    -- 反而读不到数据）。20ms 超时让 recv 不会卡住整个循环。
    -- 必须用 "*l"（读一行）：协议就是一行一帧。
    -- 曾写成 receive(4096) —— 在 LuaSocket 里那是「精确读 4096 字节」，
    -- 会一直等满 4096 才返回，于是永远 timeout，双向都收不到任何东西。
    local part, err = self.sock:receive("*l")
    if not part then
      if err == "timeout" then return nil end
      self.closed = true
      self.last_err = err
      return nil
    end
    if part == "" then -- 对端关闭
      self.closed = true
      return nil
    end
    self.buf = rest .. part .. "\n" -- receive("*l") 会吃掉换行，补回去供分帧
  end
end

-- Host 用的入口：先消化服务端暂存的 resp，再读 socket
function SockChannel:recv()
  if self.closed then return nil end
  if self.pending and #self.pending > 0 then
    return table.remove(self.pending, 1)
  end
  return self:recvRaw()
end

function SockChannel:isClosed() return self.closed end

function SockChannel:close()
  self.closed = true
  pcall(function() self.sock:close() end)
end

function Channel.wrap(sock)
  return SockChannel.create(sock)
end

-- 连到一个服务端（阻塞连接，超时 2 秒）
-- 名字不要叫 connect：静态检查会把 socket 的 sock:connect 误判成点号调用
function Channel.open(host, port)
  local socket = require "socket"
  local sock = socket.tcp()
  sock:settimeout(2)
  local ok, err = sock:connect(host or "127.0.0.1", port)
  if not ok then
    sock:close()
    return nil, err
  end
  return Channel.wrap(sock)
end

return Channel
