-- 房间：协程化游戏循环（本项目的核心设计，对应原版 Room + RoomThread）
--
-- 协程内：askForXxx 是直觉上的阻塞调用（内部 coroutine.yield 出请求）
-- 协程外：room:step(response) 唤醒并注入响应，room.pending 变为下一个请求
-- 由此，原版信号量挂起线程的模型被无损映射为协程，单机/网络共用同一语义。
--
-- 触发管线对应原版 RoomThread::trigger：
--   trigger(event, player, data) 按 priority 升序执行所有监听该事件的技能，
--   任一技能返回 true 即截断（取消结算）。返回 true 表示本次结算被取消。
local class = require "src.class"
local Cards = require "src.core.cards"
local Card = require "src.core.card"
local Player = require "src.core.player"

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
  self.win_role = nil
  self.turn_count = 0
  self.loglines = {}
  self.rng = nil         -- 可注入确定性 rng（测试用）
  self.identity_mode = false -- 身份局：启用角色胜负判定
  self.win_role = nil    -- 获胜阵营 "lord"/"rebel"/"renegade"
  for _, p in ipairs(players) do p.seat = p.seat or 0 end
end

-- ===== 身份（Role）=====
-- 各人数下的身份配置，对齐原版默认配置
Room.ROLE_SETUP = {
  [2] = { lord = 1, rebel = 1 },
  [3] = { lord = 1, loyalist = 1, rebel = 1 },
  [4] = { lord = 1, loyalist = 1, rebel = 1, renegade = 1 },
  [5] = { lord = 1, loyalist = 1, rebel = 2, renegade = 1 },
  [6] = { lord = 1, loyalist = 1, rebel = 3, renegade = 1 },
  [7] = { lord = 1, loyalist = 2, rebel = 3, renegade = 1 },
  [8] = { lord = 1, loyalist = 2, rebel = 4, renegade = 1 },
}
-- 固定遍历顺序，保证同样 rng 下洗牌结果可复现
Room.ROLE_ORDER = { "lord", "loyalist", "rebel", "renegade" }

-- 分配身份并据此调整主公体力；主公身份公开，其余隐藏
function Room:setupRoles(rng)
  local n = #self.players
  local spec = Room.ROLE_SETUP[n] or Room.ROLE_SETUP[4]
  local list = {}
  for _, role in ipairs(Room.ROLE_ORDER) do
    for _ = 1, (spec[role] or 0) do table.insert(list, role) end
  end
  -- 人数与配置不符时补反贼，避免身份缺失
  while #list < n do table.insert(list, "rebel") end

  local f = rng or math.random
  for i = #list, 2, -1 do
    local j = f(i)
    list[i], list[j] = list[j], list[i]
  end

  for i, p in ipairs(self.players) do
    p.role = list[i]
    p.role_revealed = (p.role == "lord") -- 主公明身份，其余暗置
    if p.role == "lord" then
      p.max_hp = p.max_hp + 1
      p.hp = p.max_hp
    end
  end
  self.identity_mode = true
  self:log("身份已分配：主公 %s（体力 %d）",
    self:getLord() and self:getLord().name or "-",
    self:getLord() and self:getLord().max_hp or 0)
  return self
end

function Room:getLord()
  for _, p in ipairs(self.players) do
    if p.role == "lord" then return p end
  end
  return nil
end

-- 某阵营是否还有存活者
function Room:roleAlive(role)
  for _, p in ipairs(self.players) do
    if p.alive and p.role == role then return true end
  end
  return false
end

-- ===== 随机源 =====
-- 统一走 self.rng（可注入），避免全局 math.random 破坏可复现性。
function Room:random(n)
  local rng = self.rng or math.random
  return rng(n)
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

-- ===== 触发管线 =====

-- 返回 true 表示结算被某个技能取消（对应原版「事件被截断」）
function Room:trigger(event, player, data)
  data = data or {}
  data.event = event

  local list = {}
  for _, skill in ipairs(self.engine.global_skills or {}) do
    if skill:listens(event) then table.insert(list, { skill = skill, owner = nil }) end
  end
  for _, p in ipairs(self.players) do
    local src = (p.general and p.general.skills) or {}
    for _, skill in ipairs(src) do
      if skill:listens(event) then table.insert(list, { skill = skill, owner = p }) end
    end
    for _, skill in ipairs(p.extra_skills or {}) do
      if skill:listens(event) then table.insert(list, { skill = skill, owner = p }) end
    end
  end
  if #list == 0 then return false end

  table.sort(list, function(a, b)
    return (a.skill.priority or 0) < (b.skill.priority or 0)
  end)
  for _, item in ipairs(list) do
    local who = item.owner or player
    if item.skill:onTrigger(event, self, who, data) then
      return true
    end
  end
  return false
end

-- 纯广播（不关心返回值），保留兼容旧调用点
function Room:broadcast(event, player, data)
  return self:trigger(event, player, data)
end

-- ===== 询问 API（协程内调用，阻塞语义）=====

-- 出牌阶段：主动使用一张牌；响应 {card=Card, target=Player} 或 nil（结束出牌）
function Room:askForUseCard(player)
  return coroutine.yield({ type = "askForUseCard", player = player })
end

-- 要求打出指定名称的牌（闪/桃/杀）；响应 Card 或 nil（不打出）
function Room:askForCard(player, card_name, prompt, extra)
  local req = {
    type = "askForCard", player = player,
    card_name = card_name, prompt = prompt,
  }
  if extra then for k, v in pairs(extra) do req[k] = v end end
  return coroutine.yield(req)
end

-- 弃牌阶段：弃 n 张；响应 Card 列表
function Room:askForDiscard(player, n)
  return coroutine.yield({ type = "askForDiscard", player = player, n = n })
end

-- 从给定牌列表中选择一张（五谷丰登）；响应 Card
function Room:askForChooseCard(player, cards, prompt)
  return coroutine.yield({
    type = "askForChooseCard", player = player,
    cards = cards, prompt = prompt,
  })
end

-- 令 source 玩家替 target 选择弃掉 n 张牌（过河拆桥）
function Room:askForDiscardFrom(source, target, n)
  local card = coroutine.yield({
    type = "askForDiscardFrom", player = source, target = target, n = n,
  })
  if card and target:takeCard(card) then
    self:log("%s 弃置 %s 的一张牌", target.name, card:zhName())
    table.insert(self.discardPile, card)
  end
end

-- 询问所有角色是否使用【无懈可击】抵消当前锦囊
function Room:askForNullification(use)
  -- 按座位顺序轮询是否有人使用【无懈可击】
  for _, p in ipairs(self:alivePlayers()) do
    local null = self:askForCard(p, "nullification",
      string.format("是否【无懈可击】抵消 %s 对 %s 的【%s】？",
        use.from.name, (use.to[1] and use.to[1].name) or "-", use.card:zhName()),
      { ask_target = use.to[1], ask_from = use.from })
    if null and p:takeCard(null) then
      self:log("%s 使用【无懈可击】抵消了效果", p.name)
      table.insert(self.discardPile, null)
      return true
    end
  end
  return false
end

-- ===== 日志与事件 =====

function Room:log(fmt, ...)
  local msg = string.format(fmt, ...)
  table.insert(self.loglines, msg)
  if #self.loglines > 500 then table.remove(self.loglines, 1) end
end

-- ===== 查询工具 =====

function Room:alivePlayers()
  local out = {}
  for _, p in ipairs(self.players) do
    if p.alive then table.insert(out, p) end
  end
  return out
end

function Room:otherAlivePlayers(me)
  local out = {}
  for _, p in ipairs(self.players) do
    if p.alive and p ~= me then table.insert(out, p) end
  end
  return out
end

-- 座位距离，取环形最小值，再修正 ±马
function Room:distance(a, b)
  if not a or not b or a == b then return 0 end
  local n = #self.players
  local d = math.abs(a.seat - b.seat)
  d = math.min(d, n - d)
  -- 进攻马 -1、防御马 +1；最低为 1
  local dist = d + (a:distanceModifier() or 0) + (b:defenseModifier() or 0)
  if dist < 1 then dist = 1 end
  return dist
end

function Room:seatOf(p)
  for i, q in ipairs(self.players) do
    if q == p then return i end
  end
  return 0
end

-- ===== 牌堆 =====

function Room:drawCards(p, n)
  for _ = 1, n do
    if #self.drawPile == 0 then
      if #self.discardPile == 0 then return end
      self:log("洗牌：弃牌堆 %d 张回炉", #self.discardPile)
      self:shuffle(self.discardPile)
      for _, c in ipairs(self.discardPile) do table.insert(self.drawPile, c) end
      self.discardPile = {}
    end
    local c = table.remove(self.drawPile)
    table.insert(p.hand, c)
  end
end

-- Fisher-Yates；走统一随机源，保持可复现
function Room:shuffle(cards)
  local rng = function(n) return self:random(n) end
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
end

-- 把一张牌丢进弃牌堆
function Room:throwCard(_p, card)
  table.insert(self.discardPile, card)
end

-- 从弃牌堆取回一张牌（【奸雄】等技能用）
function Room:takeFromDiscard(card)
  for i, c in ipairs(self.discardPile) do
    if c == card then return table.remove(self.discardPile, i) end
  end
  return nil
end

-- 是否可无限出杀：诸葛连弩，或武将技能标记（如【咆哮】）
function Room:allowsUnlimitedSlash(p)
  if p:hasEquip("crossbow") then return true end
  local skills = (p.general and p.general.skills) or {}
  for _, s in ipairs(skills) do
    if s.unlimited_slash then return true end
  end
  for _, s in ipairs(p.extra_skills or {}) do
    if s.unlimited_slash then return true end
  end
  return false
end

-- ===== 主循环与回合 =====

function Room:_main()
  self:trigger("GameStart", nil, { room = self })
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
  self:trigger("GameFinished", nil, { winner = self.winner })
end

function Room:_advanceSeat()
  local guard = 0
  repeat
    self.current_seat = (self.current_seat % #self.players) + 1
    guard = guard + 1
  until self.players[self.current_seat].alive or guard > 100
end

-- 回合：六阶段，对齐原版 Player::Phase
function Room:_turn(p)
  p.slash_used = false
  p.slash_count = 0
  p.drunk = false
  p.skip_play = false
  p.skip_draw = false

  self:trigger("TurnStart", p, { player = p })

  self:_phase(p, "start")
  self:_phase(p, "judge")
  self:_phase(p, "draw")
  self:_phase(p, "play")
  self:_phase(p, "discard")
  self:_phase(p, "finish")

  p.phase = "not_active"
  self:trigger("TurnEnd", p, { player = p })
end

-- 阶段机：每个阶段都发出 EventPhaseStart / EventPhaseEnd，技能可据此干预
function Room:_phase(p, name)
  if self.game_over or not p.alive then return end
  p.phase = name
  if self:trigger("EventPhaseStart", p, { player = p, phase = name }) then
    return
  end
  local fn = self["_phase_" .. name]
  if fn then fn(self, p) end
  if self.game_over or not p.alive then return end
  self:trigger("EventPhaseEnd", p, { player = p, phase = name })
end

function Room:_phase_start(_p)
end

-- 判定阶段：结算判定区里的延时锦囊
function Room:_phase_judge(p)
  while #p.judges > 0 do
    local card = p.judges[1]
    self:_judgeCard(p, card)
  end
end

function Room:_phase_draw(p)
  if p.skip_draw then
    self:log("%s 跳过摸牌阶段", p.name)
    return
  end
  local data = { player = p, n = 2 }
  self:trigger("DrawNCards", p, data)
  self:drawCards(p, data.n or 2)
  self:trigger("AfterDrawNCards", p, data)
end

function Room:_phase_play(p)
  if p.skip_play then
    self:log("%s 跳过出牌阶段", p.name)
    return
  end
  local guard = 0
  while not self.game_over and p.alive do
    guard = guard + 1
    if guard > 100 then
      self:log("出牌阶段异常：单回合动作数超过上限，强制结束")
      break
    end
    local use = self:askForUseCard(p)
    if not use then break end
    local consumed = self:useCard(p, use.card, use.target or use.to)
    if not consumed then break end -- 引擎判定非法响应，终止出牌防止死循环
  end
end

function Room:_phase_discard(p)
  local excess = #p.hand - p.hp
  if excess <= 0 then return end
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

function Room:_phase_finish(_p)
end

-- ===== 判定 =====

function Room:_judgeCard(p, card)
  p:removeJudge(card)
  local judge_card = nil
  if #self.drawPile == 0 and #self.discardPile > 0 then
    self:shuffle(self.discardPile)
    for _, c in ipairs(self.discardPile) do table.insert(self.drawPile, c) end
    self.discardPile = {}
  end
  if #self.drawPile > 0 then judge_card = table.remove(self.drawPile) end
  if not judge_card then
    table.insert(self.discardPile, card)
    return nil
  end

  self:trigger("StartJudge", p, { player = p, card = card, judge = judge_card })

  local def = Cards.get(card.name)
  local result = false
  if def and def.judge then
    result = def.judge(self, p, judge_card) == true
  end
  table.insert(self.discardPile, judge_card)
  self:trigger("FinishJudge", p, { player = p, card = card, result = result })

  if result then
    -- 延时锦囊生效后同样进入弃牌堆
    table.insert(self.discardPile, card)
    if def and def.on_judged then def.on_judged(self, p, true) end
  elseif def and def.pass_on_miss then
    -- 闪电未命中时传给下家，不进弃牌堆
    self:passLightning(p, card)
  else
    table.insert(self.discardPile, card)
  end
  return judge_card
end

-- 闪电未命中时传给下家
function Room:passLightning(from, card)
  local seat = self:seatOf(from)
  for i = 1, #self.players - 1 do
    local nxt = self.players[((seat - 1 + i) % #self.players) + 1]
    if nxt.alive and not nxt:hasDelayed("lightning") then
      nxt:addJudge(card)
      self:log("【闪电】传给 %s", nxt.name)
      return
    end
  end
  table.insert(self.discardPile, card)
end

-- ===== 卡牌使用 =====

-- target 可为单个 Player 或列表；返回 true=已消耗
function Room:useCard(from, card, target)
  local targets = target
  if target and target.is_human ~= nil then targets = { target } end
  targets = targets or {}

  if not card or not from:takeCard(card) then
    self:log("%s 的响应包含不在手牌中的卡，忽略", from.name)
    return false
  end

  local use = { from = from, card = card, to = targets }
  local def = Cards.get(card.name)

  -- AOE 类锦囊的作用目标由引擎展开，AI/UI 只需指定卡牌本身
  if def and def.target == "all_other" then
    targets = self:otherAlivePlayers(from)
    use.to = targets
  elseif def and def.target == "all" then
    targets = self:alivePlayers()
    use.to = targets
  end

  if self:trigger("PreCardUsed", from, use) then
    table.insert(from.hand, card)
    self:log("【%s】的使用被取消", card:zhName())
    return false
  end

  -- 合法性校验（退还）
  if not self:_validateUse(from, card, targets) then
    table.insert(from.hand, card)
    return false
  end

  self:trigger("CardUsed", from, use)

  -- 锦囊（含延时锦囊）可被【无懈可击】抵消
  if def and def.nullifiable and self:askForNullification(use) then
    table.insert(self.discardPile, card)
    return true
  end

  if def and Cards.isDelayed(card.name) then
    -- 延时锦囊进判定区而非弃牌堆
    local t = targets[1]
    t:addJudge(card)
    self:log("%s 对 %s 使用【%s】", from.name, t.name, card:zhName())
    return true
  end

  if def and def.ctype == Card.Type.Equip then
    self:_equipCard(from, card)
    return true
  end

  if def and def.ctype == Card.Type.Trick and def.effect then
    table.insert(self.discardPile, card)
    self:trigger("CardEffect", from, use)
    def.effect(self, use)
    self:trigger("CardFinished", from, use)
    return true
  end

  return self:_useBasic(from, card, targets)
end

-- 基本牌结算：杀 / 桃 / 酒
function Room:_useBasic(from, card, targets)
  local name = card.name

  if name == "slash" or name == "fire_slash" or name == "thunder_slash" then
    local target = targets[1]
    if from.slash_count > 0 and not self:allowsUnlimitedSlash(from) then
      self:log("%s 本回合已使用过【杀】，退还", from.name)
      table.insert(from.hand, card)
      return false
    end
    if not target or target == from or not target.alive then
      self:log("【杀】的目标非法，退还")
      table.insert(from.hand, card)
      return false
    end
    if self:distance(from, target) > from:attackRange() then
      self:log("目标不在攻击范围内（距离 %d > 范围 %d），退还",
        self:distance(from, target), from:attackRange())
      table.insert(from.hand, card)
      return false
    end
    from.slash_used = true
    from.slash_count = from.slash_count + 1
    table.insert(self.discardPile, card)
    self:_resolveSlash(from, target, card)
    return true

  elseif name == "peach" then
    if from.hp >= from.max_hp then
      self:log("%s 体力已满，不能使用【桃】，退还", from.name)
      table.insert(from.hand, card)
      return false
    end
    table.insert(self.discardPile, card)
    self:log("%s 使用【桃】", from.name)
    self:heal(from, 1)
    return true

  elseif name == "analeptic" then
    if from.hp < from.max_hp then
      table.insert(self.discardPile, card)
      self:log("%s 濒死时使用【酒】回复体力", from.name)
      self:heal(from, 1)
    else
      from.drunk = true
      table.insert(self.discardPile, card)
      self:log("%s 饮酒，下一张【杀】伤害 +1", from.name)
    end
    return true

  elseif name == "dodge" then
    -- 【闪】不能主动使用
    self:log("【闪】不能主动使用，退还")
    table.insert(from.hand, card)
    return false
  end

  self:log("%s 打出 %s（暂无结算规则）", from.name, card:zhName())
  table.insert(self.discardPile, card)
  return true
end

function Room:_validateUse(from, card, targets)
  local def = Cards.get(card.name)
  if not def then return true end
  if def.distance then
    local t = targets[1]
    if t and self:distance(from, t) > def.distance then
      self:log("目标超出【%s】的距离限制（%d > %d），退还",
        card:zhName(), self:distance(from, t), def.distance)
      return false
    end
  end
  if def.target == "none" then return true end
  if #targets == 0 and def.target ~= "self" then
    self:log("【%s】需要目标，退还", card:zhName())
    return false
  end
  return true
end

-- 装备：旧装备进弃牌堆；白银狮子失去时回血
function Room:_equipCard(from, card)
  local def = Cards.get(card.name)
  local slot = def and def.equip or "weapon"
  local old = from:equipCard(card, slot)
  if old then
    table.insert(self.discardPile, old)
    local olddef = Cards.get(old.name)
    if olddef and old.name == "silver_lion" then
      self:log("%s 失去【白银狮子】，回复 1 点体力", from.name)
      self:heal(from, 1)
    end
  end
  self:log("%s 装备【%s】", from.name, card:zhName())
end

-- ===== 杀的结算 =====

function Room:_resolveSlash(from, to, card)
  local nature = "normal"
  if card.name == "fire_slash" then nature = "fire" end
  if card.name == "thunder_slash" then nature = "thunder" end

  self:log("%s 对 %s 使用【%s】", from.name, to.name, card:zhName())

  -- 藤甲：普通杀无效
  if nature == "normal" and to:hasEquip("vine") then
    self:log("%s 的【藤甲】使普通【杀】无效", to.name)
    self:trigger("SlashMissed", to, { from = from, to = to })
    return
  end
  -- 仁王盾：黑色杀无效
  local armor = to:getArmor()
  local ignore_armor = from:hasEquip("qinggang_sword") ~= nil
  if armor and armor.name == "renwang_shield" and not ignore_armor and not card:isRed() then
    self:log("%s 的【仁王盾】使黑色【杀】无效", to.name)
    self:trigger("SlashMissed", to, { from = from, to = to })
    return
  end

  if self:trigger("SlashEffected", to, { from = from, to = to, card = card }) then
    return
  end

  local dodged = false
  local dodge = self:askForCard(to, "dodge",
    string.format("%s 对你使用【%s】，请打出【闪】", from.name, card:zhName()))
  if dodge and dodge.name == "dodge" and to:takeCard(dodge) then
    dodged = true
    table.insert(self.discardPile, dodge)
    self:log("%s 打出【闪】", to.name)
  end

  -- 八卦阵：未打出【闪】时可判定，红色视为打出【闪】
  if not dodged and to:hasEquip("eight_diagram") and not ignore_armor then
    local judge = (#self.drawPile > 0) and table.remove(self.drawPile) or nil
    if judge then
      local red = judge:isRed()
      table.insert(self.discardPile, judge)
      self:log("%s 的【八卦阵】判定 %s %s", to.name, judge:suitString(),
        red and "红色，视为打出【闪】" or "黑色，防具失效")
      dodged = red
    end
  end

  if dodged then
    self:trigger("SlashMissed", to, { from = from, to = to })
    return
  end

  -- 命中
  self:trigger("SlashHit", to, { from = from, to = to, card = card })

  -- 寒冰剑：改为弃两张牌
  if from:hasEquip("ice_sword") then
    self:log("%s 的【寒冰剑】改为弃置 %s 两张牌", from.name, to.name)
    self:askForDiscardFrom(from, to, 2)
    return
  end

  local n = 1
  if from.drunk then
    n = n + 1
    from.drunk = false
    self:log("【酒】使伤害 +1")
  end
  if nature == "fire" and to:hasEquip("vine") then
    n = n + 1
    self:log("【藤甲】使火焰伤害 +1")
  end

  self:damage(from, to, n, nature, card)

  -- 麒麟弓：命中后弃目标一匹马
  if from:hasEquip("kylin_bow") and to.alive then
    for _, slot in ipairs { "offensive_horse", "defensive_horse" } do
      local horse = to.equips[slot]
      if horse then
        to.equips[slot] = nil
        table.insert(self.discardPile, horse)
        self:log("%s 的【麒麟弓】击落 %s 的【%s】", from.name, to.name, horse:zhName())
        break
      end
    end
  end
end

-- ===== 伤害/治疗/死亡 =====
-- nature: "normal" / "fire" / "thunder"；card 为造成伤害的那张牌（【奸雄】等技能需要）
function Room:damage(from, to, n, nature, card)
  nature = nature or "normal"
  local data = { from = from, to = to, n = n, nature = nature, card = card }

  if self:trigger("DamageForseen", to, data) then return end
  if from and self:trigger("DamageCaused", from, data) then return end
  if self:trigger("DamageInflicted", to, data) then return end

  -- 白银狮子：伤害大于 1 时改为 1
  local armor = to:getArmor()
  local ignore_armor = from and from:hasEquip("qinggang_sword") ~= nil
  if armor and armor.name == "silver_lion" and data.n > 1 and not ignore_armor then
    self:log("%s 的【白银狮子】将伤害削减为 1", to.name)
    data.n = 1
  end

  if self:trigger("PreDamageDone", to, data) then return end

  n = data.n
  to.hp = to.hp - n
  self:log("%s 受到 %s 造成的 %d 点%s伤害（剩 %d 体力）",
    to.name, from and from.name or "系统", n,
    nature == "fire" and "火焰" or nature == "thunder" and "雷" or "",
    math.max(to.hp, 0))

  self:trigger("DamageDone", to, data)
  self:trigger("Damage", to, data)
  self:trigger("Damaged", to, data)

  -- 铁索连环传导
  if nature ~= "normal" and to.chained then
    self:_spreadChain(to, from, n, nature)
  end

  self:trigger("DamageComplete", to, data)

  if to.hp <= 0 then
    to.hp = 0
    self:_dying(to, from)
  end
end

-- 属性伤害传导到所有处于连环状态的角色（单次传导，不再级联）
function Room:_spreadChain(origin, from, n, nature)
  self:log("【%s】伤害沿铁索连环传导", nature == "fire" and "火" or "雷")
  for _, p in ipairs(self.players) do
    if p ~= origin and p.chained and p.alive then
      self:log("铁索连环：伤害传导至 %s", p.name)
      local data = { from = from, to = p, n = n, nature = nature }
      if not self:trigger("DamageInflicted", p, data) then
        p.hp = p.hp - n
        if p.hp <= 0 then
          p.hp = 0
          self:_dying(p, from)
        else
          self:trigger("Damaged", p, data)
        end
      end
    end
  end
end

function Room:heal(p, n)
  if p.hp < p.max_hp then
    p.hp = math.min(p.hp + n, p.max_hp)
    self:log("%s 回复 %d 点体力（现 %d）", p.name, n, p.hp)
  end
end

function Room:_dying(p, killer)
  self:trigger("Dying", p, { player = p })
  self:log("%s 濒死，请求【桃】", p.name)
  while p.hp <= 0 do
    local peach = self:askForCard(p, "peach", "你已濒死，请使用【桃】/【酒】（不出则阵亡）")
    if peach and p:takeCard(peach) then
      table.insert(self.discardPile, peach)
      self:log("%s 使用【桃】", p.name)
      self:heal(p, 1)
    else
      local wines = p:findCardsByName("analeptic")
      if #wines > 0 then
        local wine = p:takeCard(wines[1])
        table.insert(self.discardPile, wine)
        self:log("%s 使用【酒】回复体力", p.name)
        self:heal(p, 1)
      else
        self:_kill(p, killer)
        return
      end
    end
  end
  self:trigger("QuitDying", p, { player = p })
end

function Room:_kill(p, killer)
  p.alive = false
  p.role_revealed = true -- 阵亡即亮身份
  self:trigger("Death", p, { player = p })
  self:log("%s 阵亡（身份：%s）", p.name, Player.ROLE_ZH[p.role] or "未知")
  for i = #p.hand, 1, -1 do
    table.insert(self.discardPile, table.remove(p.hand, i))
  end
  for _, card in ipairs(p.judges) do table.insert(self.discardPile, card) end
  p.judges = {}
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    local e = p.equips[slot]
    if e then table.insert(self.discardPile, e) end
    p.equips[slot] = nil
  end
  self:_rewardAndPunish(killer, p)
  self:_checkWinner()
end

-- 奖惩：击败反贼摸 3 张；主公误杀忠臣则弃光全部牌与装备
function Room:_rewardAndPunish(killer, victim)
  if not killer or not killer.alive or killer == victim then return end
  if victim.role == "rebel" then
    self:log("%s 击败反贼，摸 3 张牌", killer.name)
    self:drawCards(killer, 3)
  elseif victim.role == "loyalist" and killer.role == "lord" then
    self:log("主公误杀忠臣，弃置所有手牌与装备")
    for i = #killer.hand, 1, -1 do
      table.insert(self.discardPile, table.remove(killer.hand, i))
    end
    for _, slot in ipairs(Player.EQUIP_SLOTS) do
      local e = killer.equips[slot]
      if e then table.insert(self.discardPile, e) end
      killer.equips[slot] = nil
    end
  end
end

function Room:_checkWinner()
  if self.identity_mode then
    self:_checkIdentityWinner()
  else
    self:_checkLastManStanding()
  end
end

function Room:_checkLastManStanding()
  local alive = self:alivePlayers()
  if #alive <= 1 then
    self.game_over = true
    self.winner = alive[1]
    self.win_role = self.winner and self.winner.role or nil
    self:log("游戏结束，%s 获胜", self.winner and self.winner.name or "无人")
  end
end

-- 身份局胜负：
--   主公阵亡 → 仅剩内奸一人则内奸胜，否则反贼胜
--   反贼与内奸全部覆灭 → 主公/忠臣方胜
function Room:_checkIdentityWinner()
  local alive = self:alivePlayers()
  local lord = self:getLord()

  if not lord or not lord.alive then
    self.game_over = true
    if #alive == 1 and alive[1].role == "renegade" then
      self.winner, self.win_role = alive[1], "renegade"
      self:log("主公已阵亡，仅存内奸 %s —— 内奸获胜", alive[1].name)
    else
      self.winner, self.win_role = nil, "rebel"
      self:log("主公已阵亡 —— 反贼获胜")
    end
    return
  end

  if not self:roleAlive("rebel") and not self:roleAlive("renegade") then
    self.game_over = true
    self.winner, self.win_role = lord, "lord"
    self:log("反贼与内奸均已覆灭 —— 主公与忠臣获胜")
    return
  end

  if #alive <= 1 then
    self.game_over = true
    self.winner = alive[1]
    self.win_role = alive[1] and alive[1].role or nil
    self:log("游戏结束，%s 获胜", self.winner and self.winner.name or "无人")
  end
end

return Room
