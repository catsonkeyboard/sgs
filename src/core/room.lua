-- 房间：协程化游戏循环（本项目的核心设计，对应原版 Room + RoomThread）
--
-- 协程内：askForXxx 是直觉上的阻塞调用（内部 coroutine.yield 出请求）
-- 协程外：room:step(response) 唤醒并注入响应，room.pending 变为下一个请求
-- 由此，原版信号量挂起线程的模型被无损映射为协程，单机/网络共用同一语义。
local class = require "src.class"

local Room = class("Room")

Room.MAX_TURNS = 300 -- 防死循环保险（测试断言用）

function Room:init(engine, players)
  assert(#players >= 2, "至少两名玩家")
  self.engine = engine
  self.players = players
  self.current_seat = 1
  self.drawPile = {}
  self.discardPile = {}
  self.co = nil
  self.pending = nil     -- 当前等待响应的请求 {type=..., player=..., ...}
  self.game_over = false
  self.winner = nil
  self.turn_count = 0
  self.loglines = {}
end

-- ===== 推进接口（协程外调用）=====

function Room:start()
  self.co = coroutine.create(function() self:_main() end)
  self:_resume(nil)
end

function Room:step(response)
  assert(self.co and not self.game_over, "房间未开始或已结束")
  self:_resume(response)
end

function Room:_resume(response)
  local results = { coroutine.resume(self.co, response) }
  local ok = table.remove(results, 1)
  if not ok then
    error("房间协程错误: " .. tostring(results[1]), 0)
  end
  if coroutine.status(self.co) == "dead" then
    self.game_over = true
    self.pending = nil
  else
    self.pending = results[1]
  end
end

-- ===== 询问 API（协程内调用，阻塞语义）=====

-- 出牌阶段：主动使用一张牌；响应 {card=Card, target=Player} 或 nil（结束出牌）
function Room:askForUseCard(player)
  return coroutine.yield({ type = "askForUseCard", player = player })
end

-- 要求打出指定名称的牌（闪/桃）；响应 Card 或 nil（不打出）
function Room:askForCard(player, card_name, prompt)
  return coroutine.yield({
    type = "askForCard", player = player,
    card_name = card_name, prompt = prompt,
  })
end

-- 弃牌阶段：弃 n 张；响应 Card 列表
function Room:askForDiscard(player, n)
  return coroutine.yield({ type = "askForDiscard", player = player, n = n })
end

-- ===== 日志与事件 =====

function Room:log(fmt, ...)
  local msg = string.format(fmt, ...)
  table.insert(self.loglines, msg)
  if #self.loglines > 500 then table.remove(self.loglines, 1) end
end

function Room:broadcast(event, data)
  for _, skill in ipairs(self.engine.global_skills) do
    if skill.events and skill.events[event] then
      skill:onTrigger(event, self, data)
    end
  end
  -- 武将个人技能（阶段 A1 扩展点）：遍历玩家 general.skills
end

-- ===== 主循环与回合 =====

function Room:_main()
  self:broadcast("GameStart", { room = self })
  self:log("游戏开始，%d 名玩家", #self.players)
  for _, p in ipairs(self.players) do
    self:drawCards(p, 4)
  end
  while not self.game_over do
    self.turn_count = self.turn_count + 1
    if self.turn_count > Room.MAX_TURNS then
      error("超过最大回合数，疑似死循环", 0)
    end
    local p = self.players[self.current_seat]
    if p.alive then self:_turn(p) end
    if not self.game_over then self:_advanceSeat() end
  end
end

function Room:_advanceSeat()
  repeat
    self.current_seat = (self.current_seat % #self.players) + 1
  until self.players[self.current_seat].alive
end

function Room:_turn(p)
  p.phase = "play"
  self:broadcast("TurnStart", { player = p })
  self:log("—— %s 的回合（第 %d 轮）", p.name, self.turn_count)
  self:drawCards(p, 2)
  p.slash_used = false

  while not self.game_over do
    local use = self:askForUseCard(p)
    if not use then break end
    local consumed = self:useCard(p, use.card, use.target)
    if not consumed then break end -- 引擎判定非法响应，终止出牌防止死循环
  end
  if self.game_over then return end

  -- 弃牌阶段：手牌上限 = 当前体力
  local excess = #p.hand - p.hp
  if excess > 0 then
    local discarded = self:askForDiscard(p, excess)
    local n = 0
    for _, c in ipairs(discarded or {}) do
      if p:takeCard(c) then
        table.insert(self.discardPile, c)
        n = n + 1
      end
    end
    if n > 0 then self:log("%s 弃置 %d 张牌", p.name, n) end
  end

  p.phase = "not_active"
  self:broadcast("TurnEnd", { player = p })
end

-- ===== 卡牌结算 =====

-- 返回 true=已消耗；false=非法响应（未消耗）
function Room:useCard(from, card, target)
  if not card or not from:takeCard(card) then
    self:log("%s 的响应包含不在手牌中的卡，忽略", from.name)
    return false
  end
  if card.name == "slash" then
    if from.slash_used then
      self:log("%s 本回合已使用过【杀】，退还", from.name)
      table.insert(from.hand, card)
      return false
    end
    from.slash_used = true
  end
  if card.name == "peach" and from.hp >= from.max_hp then
    self:log("%s 体力已满，不能使用【桃】，退还", from.name)
    table.insert(from.hand, card)
    return false
  end
  if card.name == "slash" and (not target or target == from or not target.alive) then
    self:log("【杀】的目标非法，退还")
    table.insert(from.hand, card)
    from.slash_used = false
    return false
  end

  self:broadcast("CardUsed", { from = from, card = card, to = target })
  table.insert(self.discardPile, card)

  if card.name == "slash" then
    self:_resolveSlash(from, target)
  elseif card.name == "peach" then
    self:log("%s 使用【桃】", from.name)
    self:heal(from, 1)
  else
    self:log("%s 打出 %s（暂无结算规则）", from.name, card:displayName())
  end
  return true
end

function Room:_resolveSlash(from, to)
  self:log("%s 对 %s 使用【杀】", from.name, to.name)
  local dodge = self:askForCard(to, "dodge", string.format("%s 对你使用【杀】，请打出【闪】", from.name))
  if dodge and to:takeCard(dodge) then
    self:log("%s 打出【闪】", to.name)
    table.insert(self.discardPile, dodge)
  else
    self:damage(from, to, 1)
  end
end

-- ===== 伤害/治疗/死亡 =====

function Room:damage(from, to, n)
  self:broadcast("DamageCaused", { from = from, to = to, n = n })
  to.hp = to.hp - n
  self:log("%s 受到 %s 造成的 %d 点伤害（剩 %d 体力）",
    to.name, from and from.name or "系统", n, math.max(to.hp, 0))
  self:broadcast("Damaged", { from = from, to = to, n = n })
  if to.hp <= 0 then
    to.hp = 0
    self:_dying(to)
  end
end

function Room:_dying(p)
  self:broadcast("Dying", { player = p })
  self:log("%s 濒死，请求【桃】", p.name)
  while p.hp <= 0 do
    local peach = self:askForCard(p, "peach", "你已濒死，请使用【桃】（不出则阵亡）")
    if not peach or not p:takeCard(peach) then
      self:_kill(p)
      return
    end
    table.insert(self.discardPile, peach)
    self:log("%s 使用【桃】", p.name)
    self:heal(p, 1)
  end
end

function Room:_kill(p)
  p.alive = false
  self:broadcast("Death", { player = p })
  self:log("%s 阵亡", p.name)
  for i = #p.hand, 1, -1 do
    table.insert(self.discardPile, table.remove(p.hand, i))
  end
  self:_checkWinner()
end

function Room:_checkWinner()
  local alive = {}
  for _, p in ipairs(self.players) do
    if p.alive then table.insert(alive, p) end
  end
  if #alive <= 1 then
    self.game_over = true
    self.winner = alive[1]
    self:log("游戏结束，%s 获胜", self.winner and self.winner.name or "无人")
  end
end

function Room:heal(p, n)
  if p.hp < p.max_hp then
    p.hp = math.min(p.hp + n, p.max_hp)
    self:log("%s 回复 %d 点体力（现 %d）", p.name, n, p.hp)
  end
end

-- ===== 牌堆 =====

function Room:drawCards(p, n)
  for _ = 1, n do
    if #self.drawPile == 0 then
      if #self.discardPile == 0 then error("牌堆与弃牌堆均空", 0) end
      self:log("洗牌：弃牌堆 %d 张回炉", #self.discardPile)
      self._rng = self._rng or math.random
      self:shuffle(self.discardPile)
      self.drawPile, self.discardPile = self.discardPile, {}
    end
    local c = table.remove(self.drawPile)
    table.insert(p.hand, c)
  end
end

-- Fisher-Yates；可选注入确定性 rng（测试用）
function Room:shuffle(cards, rng)
  rng = rng or math.random
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
end

return Room
