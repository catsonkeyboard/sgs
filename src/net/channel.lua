-- 通道：Host 与外界的唯一接口。两种实现：
--   memory  —— 内存队列，测试用（完全确定、不占端口）
--   socket  —— LuaSocket TCP，真实联机用（见 server.lua / client.lua）
local class = require "src.class"

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

return Channel
