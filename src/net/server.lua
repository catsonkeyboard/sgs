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

function Server:init(port, count, minStart)
  self.port = port or 9527
  self.host = Host.create { count = count or 5, minStart = minStart or 2 }
  self.clients = {} -- channel -> seat
  self.specs = {}    -- 观战者 channel
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
    -- 对局进行中新连入的人：先观战，下一局再上场。
    -- 否则他会占到一个座位，但当前 room.players 里并没有他，
    -- 既收不到请求又占着位置（实测踩过）。
    if self.host.room and not self.host.room.game_over then
      self.host:addSpectator(ch)
      self.specs[ch] = true
      ch:send { type = "spectating", seats = self.host:seatInfo(),
        chats = self.host.chats }
      print("[服务端] 对局进行中，新连接先观战（下一局上场）")
    else
    local seat, tok = self.host:attach(nil, ch)
    if not seat then
      ch:send { type = "error", message = err or "房间已满" }
      ch:close()
    else
      self.clients[ch] = seat
      ch:send {
        type = "welcome", seat = seat, count = self.host.count,
        token = tok, -- 掉线后凭它认回座位
        seats = self.host:seatInfo(),
        chats = self.host.chats,
      }
      self.host:broadcast { type = "seats", seats = self.host:seatInfo() }
      print(string.format("[服务端] 座位 %d 接入（已准备 %d/%d 人开局）",
        seat, self.host:readyCount(), self.host.minStart or 2))
    end
    end
  end
end

-- 收取各客户端消息；resp 暂存到 pending，等 Host:tick 来取
function Server:drain()
  for ch, seat in pairs(self.clients) do
    if ch:isClosed() then
      if self.specs[ch] then
        self.host:removeSpectator(ch)
        self.specs[ch] = nil
        self.clients[ch] = nil
        print("[服务端] 观战者离开")
      else
        -- 保留座位等待重连（宽限 60 秒），不是立刻清空
        self.host:dropSeat(seat)
        self.clients[ch] = nil
        print(string.format("[服务端] 座位 %d 掉线（%d 秒内可重连）", seat, 60))
      end
    else
      local msg = ch:recvRaw()
      while msg do
        local t = msg.type
        if t == "hello" then
          if msg.spectate then
            -- 观战：让出座位，只收 log/state
            self.host:detach(seat)
            self.clients[ch] = nil
            self.host:addSpectator(ch, msg.name)
            self.specs[ch] = true
            ch:send { type = "spectating", seats = self.host:seatInfo(),
              chats = self.host.chats }
            print(string.format("[服务端] %s 进入观战", msg.name or "?"))
          else
            local s = self.host.seats[seat]
            if s then
              s.name = msg.name or s.name
              -- 聊天历史补发
              for _, c in ipairs(self.host.chats) do ch:send(c) end
            end
          end
        elseif t == "resume" then
          -- 重连：凭令牌坐回原座
          local s2 = self.host:resumeSeat(ch, msg.token)
          if s2 then
            self.clients[ch] = s2
            local st = self.host.seats[s2]
            ch:send { type = "welcome", seat = s2, count = self.host.count,
              token = msg.token, resumed = true, seats = self.host:seatInfo() }
            if self.host.room then self.host:flushState(true) end
            print(string.format("[服务端] 座位 %d 重连成功", s2))
          else
            ch:send { type = "error", message = "重连失败（令牌无效或已超时）" }
          end
        elseif t == "chat" then
          local s3 = self.host.seats[seat]
          self.host:chat(seat, (s3 and s3.name) or ("座位" .. seat), tostring(msg.text or ""))
        elseif t == "ready" then
          local s = self.host.seats[seat]
          if s then s.ready = msg.ready ~= false end
          self.host:broadcast { type = "seats", seats = self.host:seatInfo() }
          print(string.format("[服务端] 座位 %d ready=%s", seat, tostring(s and s.ready)))
        elseif t == "resp" then
          ch.pending = ch.pending or {}
          table.insert(ch.pending, msg)
        end
        msg = ch:recvRaw()
      end
    end
  end

  -- 观战者也要 drain：他们不在 clients 里（没占座），
  -- 否则他们发的聊天/重连消息永远没人读
  local alive = {}
  for _, sp in ipairs(self.host.spectators) do
    local ch = sp.channel
    if ch:isClosed() then
      self.specs[ch] = nil
    else
      table.insert(alive, sp)
      local msg = ch:recvRaw()
      while msg do
        if msg.type == "chat" then
          self.host:chat(nil, sp.name or "观战者", tostring(msg.text or ""))
        elseif msg.type == "hello" then
          sp.name = msg.name or sp.name
        end
        msg = ch:recvRaw()
      end
    end
  end
  self.host.spectators = alive
end

function Server:pump()
  self:acceptAll()
  self:drain()

  local h = self.host

  -- 对局已结束：广播结果后把 ready 清掉，等大家重新准备再开下一局。
  -- 注意这里**不能退出** —— 否则后来的人（比如观战者）根本连不上。
  if h.room and h.room.game_over then
    if not self._over_logged then
      self._over_logged = true
      print("[服务端] 对局结束，胜者="
        .. tostring(h.room.winner and h.room.winner.name))
      for _, st in ipairs(h.seats) do if st.channel then st.ready = false end end
      h:broadcast { type = "seats", seats = h:seatInfo() }
    end
    if h:canStart() then
      self._over_logged = false
      local seed = os.time() % 2147483647
      h:startGame(seed)
      h:broadcast { type = "start", seed = seed }
      print("[服务端] 新一局开始，seed=" .. seed)
    end
    return
  end

  if not h.room then
    if h:canStart() then
      local seed = os.time() % 2147483647
      h:startGame(seed)
      h:broadcast { type = "start", seed = seed }
      print("[服务端] 开局，seed=" .. seed)
    end
    return
  end

  h:tick()
end

-- 主动停止（供外部调用；正常情况服务端常驻）
function Server:stop() self.finished = true end

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
