-- Host：房间 / 座位 / 同步 的权威层（服务端唯一真相）
--
-- 它不碰 socket，只认「通道」（channel）。通道接口极简：
--   channel:send(msg_table)   下发一条消息
--   channel:recv() -> table?  取一条已收到的消息（没有则 nil）
--
-- 这样设计的好处：真实网络用 socket 通道，测试用内存通道，
-- 同一套 Host 逻辑两边都能跑，且测试完全确定（不依赖端口/时序）。
--
-- 座位模型：
--   座位 1..N 固定；连上来的客户端占座（人类），空座由 BOT 顶替。
--   Driver 遇到人类请求会返回 "human"，Host 就把请求发给对应通道并等待。
local class = require "src.class"
local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local Bot = require "src.core.bot"
local Protocol = require "src.net.protocol"

local Host = class("Host")

function Host:init(opts)
  opts = opts or {}
  self.count = opts.count or 5 -- 默认 5 人局（8 人为官方标准局，见 README）
  self.seat_count = self.count
  self.seats = {}
  for i = 1, self.count do
    self.seats[i] = { index = i, name = nil, channel = nil, ready = false }
  end
  self.room = nil
  self.driver = nil
  self.next_req_id = 1
  self.waiting = nil   -- { seat=, id= }
  self.last_log = 0
  self.spectators = {} -- 只收 log/state，不占座、不会被请求
  self.chats = {}      -- 聊天记录（新连入的人也能看到历史）
  self.general_names = opts.generals or { "张飞", "曹操", "司马懿", "华佗" }
end

-- 座位表（可下发给客户端）
function Host:seatInfo()
  local out = {}
  for i, s in ipairs(self.seats) do
    table.insert(out, {
      index = i, name = s.name, occupied = s.channel ~= nil, ready = s.ready,
    })
  end
  return out
end

-- 找第一个空座；没有返回 nil
function Host:freeSeat()
  for i, s in ipairs(self.seats) do
    if not s.channel then return i end
  end
  return nil
end

function Host:attach(name, channel)
  local i = self:freeSeat()
  if not i then return nil, "房间已满" end
  local s = self.seats[i]
  s.name = name or ("玩家" .. i)
  s.channel = channel
  s.ready = false
  s.dropped_at = nil
  -- 重连令牌在占座时就生成并随 welcome 下发，掉线后凭它认座
  s.resume_token = string.format("s%d-%d-%d", i, os.time(), math.random(100000))
  return i, s.resume_token
end

-- 掉线：保留座位一段时间（宽限期内可重连），不是立即清空
function Host:dropSeat(seat)
  local s = self.seats[seat]
  if not s then return end
  s.channel = nil
  s.dropped_at = os.time()
end

-- 重连：宽限期内且令牌一致才能坐回原位
function Host:resumeSeat(channel, token)
  for i, s in ipairs(self.seats) do
    if not s.channel and s.resume_token == token then
      if not s.dropped_at then return nil end
      if os.time() - (s.dropped_at or 0) > RESUME_GRACE then
        s.dropped_at = nil
        return nil
      end
      s.channel = channel
      s.dropped_at = nil
      return i
    end
  end
  return nil
end

-- 观战：不占座
function Host:addSpectator(ch, name)
  table.insert(self.spectators, { channel = ch, name = name or "观战者" })
end

function Host:removeSpectator(ch)
  for i, sp in ipairs(self.spectators) do
    if sp.channel == ch then table.remove(self.spectators, i) return true end
  end
  return false
end

-- 聊天：记历史并广播
function Host:chat(seat, name, text)
  local msg = { type = "chat", seat = seat, name = name, text = text }
  table.insert(self.chats, msg)
  if #self.chats > 50 then table.remove(self.chats, 1) end
  self:broadcast(msg)
end

function Host:detach(seat)
  local s = self.seats[seat]
  if not s then return end
  s.channel = nil
  s.name = nil
  s.ready = false
  -- 正在等这个人应答就直接判「放弃」继续推进，避免整局卡住
  if self.waiting and self.waiting.seat == seat then
    self.waiting = nil
    if self.room and self.room.pending then self.room:step(nil) end
  end
end

function Host:allReady()
  for _, s in ipairs(self.seats) do
    if not s.channel or not s.ready then return false end
  end
  return true
end

-- 开局条件：至少 1 人连接，且**所有已连接者**都 ready。
-- （空座会由 BOT 顶替，所以不要求坐满 —— 1 人也能开局试玩）
function Host:canStart()
  local n = 0
  for _, s in ipairs(self.seats) do
    if s.channel then
      n = n + 1
      if not s.ready then return false end
    end
  end
  return n > 0
end

-- 局面变化时广播快照（不是每帧都发，避免刷屏）
function Host:flushState(force)
  if not self.room then return end
  local key = tostring(self.room.turn_count) .. ":" .. tostring(self.room.current_seat)
    .. ":" .. tostring(self.room.game_over)
  if force or key ~= self._state_key then
    self._state_key = key
    self:broadcast { type = "state", snapshot = self:snapshot() }
  end
end

-- 结束时广播一次结果
function Host:flushOver()
  if not self.room or not self.room.game_over then return end
  if self._over_sent then return end
  self._over_sent = true
  self:broadcast {
    type = "over",
    winner = self.room.winner and self.room.winner.name or nil,
    win_role = self.room.win_role,
  }
end

-- 建局：有客户端的座位是人类，其余由 BOT 顶上
function Host:startGame(seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local players = {}
  for i = 1, self.count do
    local s = self.seats[i]
    local gname = self.general_names[((i - 1) % #self.general_names) + 1]
    local g = engine:getGeneral(gname) or engine:getGeneral("白板武将")
    local is_human = s.channel ~= nil
    local p = Player.create(is_human and (s.name or ("玩家" .. i)) or ("BOT·" .. g.name),
      g, i, is_human)
    table.insert(players, p)
  end
  self.players = players
  self.room = Room.create(engine, players)
  self.room.drawPile = Standard.buildDrawPile(seed or 1)
  self.room.rng = Standard.makeRng(seed or 1)
  if self.count >= 4 then self.room:setupRoles(Standard.makeRng((seed or 1) + 1)) end
  self.room:start()
  self.driver = Driver.create(self.room, Bot.make())
  self.seatOfPlayer = function(p)
    for i, q in ipairs(players) do if q == p then return i end end
    return nil
  end
  self.last_log = 0
  self._over_sent = false
  self._state_key = nil
  self:flushState(true)
  return true
end

-- 广播一条消息给所有在线客户端
function Host:broadcast(msg)
  for _, s in ipairs(self.seats) do
    if s.channel then
      local ok = pcall(function() s.channel:send(msg) end)
      if not ok then self:dropSeat(s.index) end
    end
  end
  -- 观战者同样收到（只是不会被发请求）
  for _, sp in ipairs(self.spectators) do
    pcall(function() sp.channel:send(msg) end)
  end
end

-- 掉线宽限（秒）：超时未重连则座位让出，等待中的请求判为放弃
RESUME_GRACE = 60

-- 宽限是否到期
local function graceExpired(s)
  return not s.dropped_at or (os.time() - s.dropped_at) > RESUME_GRACE
end

-- 增量日志（只发新增部分）
function Host:flushLog()
  if not self.room then return end
  local lines = self.room.loglines or {}
  if #lines > self.last_log then
    local out = {}
    for i = self.last_log + 1, #lines do table.insert(out, lines[i]) end
    self.last_log = #lines
    self:broadcast { type = "log", lines = out }
  end
end

-- 推进一帧。返回 "waiting"（等某个人类应答）/ "over" / "running"
function Host:tick()
  if not self.room then return "idle" end
  self:flushLog()
  self:flushState()
  if self.room.game_over then
    self:flushOver()
    return "over"
  end

  -- 已有请求在等人？看看应答到了没
  if self.waiting then
    local s = self.seats[self.waiting.seat]
    -- 掉线宽限期内**继续等**，给重连留出时间；过期才判放弃
    if s and not s.channel and s.dropped_at and not graceExpired(s) then
      return "waiting"
    end
    if not s or not s.channel then
      self.waiting = nil
      if self.room.pending then self.room:step(nil) end
      return "running"
    end
    local msg = s.channel:recv()
    while msg do
      if msg.type == "resp" and msg.id == self.waiting.id then
        self.waiting = nil
        self.room:step(self:toResponse(msg))
        -- 对局也可能是在这次应答后结束的（比如应答者阵亡导致胜负已定），
        -- 这个分支直接 return，必须补一次结束广播，否则 over 消息时有时无
        if self.room.game_over then self:flushOver() end
        return "running"
      end
      msg = s.channel:recv()
    end
    return "waiting"
  end

  local st = self.driver:advance()
  -- 对局常在 advance() 内部就结束了，这里必须补一次结束广播，
  -- 否则 tick 直接返回 "over"，客户端永远收不到 over 消息
  if self.room and self.room.game_over then self:flushOver() end
  if st == "human" then
    local req = self.room.pending
    local seat = req and req.player and self.seatOfPlayer(req.player) or nil
    if not seat then -- 拿不到座位就交给 BOT 兜底，避免卡死
      self.room:step(Bot.make()(req, self.room))
      return "running"
    end
    local id = self.next_req_id
    self.next_req_id = self.next_req_id + 1
    self.waiting = { seat = seat, id = id }
    local s = self.seats[seat]
    if s and s.channel then
      s.channel:send(Protocol.makeRequest(id, req, self.seatOfPlayer))
    end
    return "waiting"
  end
  return st -- "over"
end

-- 客户端应答 → 引擎需要的响应
function Host:toResponse(msg)
  if msg.value == false then return nil end
  if msg.value ~= nil then return msg.value end
  local room = self.room
  local req = room and room.pending
  if not req then return nil end
  local p = req.player

  -- 按 seat 定位目标（客户端只知道座位号）
  local target = nil
  if msg.target_seat then
    target = self.players[msg.target_seat]
  end
  -- 按 card id 定位牌
  local function findCard(id)
    for _, c in ipairs(p.hand) do if c.id == id then return c end end
    return nil
  end
  if msg.card_id then
    local c = findCard(msg.card_id)
    if c then
      return target and { card = c, target = target } or c
    end
  end
  if msg.card_ids then
    local out = {}
    for _, id in ipairs(msg.card_ids) do
      local c = findCard(id)
      if c then table.insert(out, c) end
    end
    return out
  end
  return true
end

-- 局面快照（给观战/断线重连用）
function Host:snapshot()
  if not self.room then return nil end
  local r = self.room
  local players = {}
  for i, p in ipairs(self.players or {}) do
    table.insert(players, {
      seat = i, name = p.name, hp = p.hp, max_hp = p.max_hp, alive = p.alive,
      hand = #p.hand,
      general = p.general and p.general.name or nil,
      role = (p.role_revealed or not p.alive) and p.role or nil,
    })
  end
  return {
    turn = r.turn_count,
    current = r.current_seat,
    phase = (r.players[r.current_seat] or {}).phase,
    draw = #r.drawPile,
    discard = #r.discardPile,
    players = players,
    over = r.game_over,
    winner = r.winner and r.winner.name or nil,
  }
end

return Host
