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
local Generals = require "src.core.generals"

local Room = class("Room")

Room.MAX_TURNS = 300  -- 防死循环保险（真正的 bug 会撞在这里）
Room.STALL_LIMIT = 80 -- 连续多少回合「无人阵亡」就判平局

-- 拉锯检测：残局里双方各摸 2 张、各出 1 张【杀】/【闪】时，谁也死不了，
-- 属于合法但打不完的局面。与其让它无限跑下去，不如判平局收场——
-- 真正的死循环仍由 MAX_TURNS 兜住。
-- 判据只看「存活人数」：血量会因零碎伤害来回变化，看血量会让计数反复清零。
function Room:_checkStall()
  local sig = 0
  for _, p in ipairs(self.players) do
    if p.alive then sig = sig + 1 end
  end
  if sig == self._stall_sig then
    self._stall_turns = (self._stall_turns or 0) + 1
  else
    self._stall_turns = 0
    self._stall_sig = sig
  end
  if self._stall_turns >= Room.STALL_LIMIT then
    self:log("连续 %d 个回合无人受伤或阵亡，判定为平局", Room.STALL_LIMIT)
    self.game_over = true
    self.winner = nil
    return true
  end
  return false
end

-- 阶段中文名（日志与跳过提示用）
Room.PHASE_ZH = {
  start = "开始", judge = "判定", draw = "摸牌",
  play = "出牌", discard = "弃牌", finish = "结束",
}

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
    -- 人类玩家的非锁定技要先征询：否则技能会像 BOT 一样自动发动，
    -- 玩家根本没有「发不发动」的选择权。锁定技（Compulsory）照常自动结算。
    if who and who.is_human and item.owner
      and not self:isCompulsorySkill(item.skill)
      and not self:askForSkillInvoke(who, item.skill) then
      -- 玩家选择不发动，跳过该技能
    elseif item.skill:onTrigger(event, self, who, data) then
      return true
    end
  end
  return false
end

-- 锁定技/限定技不征询：锁定技必须发动，限定技的发动时机由技能自身判定
function Room:isCompulsorySkill(skill)
  local f = skill and skill.frequency
  return f == "Compulsory" or f == "Wake"
end

-- 询问是否发动某个武将技；BOT 一律发动，人类玩家弹选择。
-- skill 可以是技能对象，也可以是技能名字符串（兼容层按原版签名为字符串）。
function Room:askForSkillInvoke(player, skill)
  if not (player and player.is_human) then return true end
  local name = type(skill) == "string" and skill
    or (skill and (skill.zh or skill.name) or "技能")
  local res = coroutine.yield({
    type = "askForSkillInvoke",
    player = player,
    skill = name,
  })
  return res == true
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
  -- 原版 room:askForCard 的第 4 个参数起是 data/method/who 等非表参数，忽略之
  if type(extra) == "table" then
    for k, v in pairs(extra) do req[k] = v end
  end
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

-- 表现层钩子：UI 用来挂音频与动效。core 只做「调用回调」，
-- 不关心谁在听，因此不产生对 UI 的依赖。
function Room:onEvent(name, fn)
  self.listeners = self.listeners or {}
  self.listeners[name] = self.listeners[name] or {}
  table.insert(self.listeners[name], fn)
end

function Room:emit(name, data)
  if not self.listeners then return end
  for _, fn in ipairs(self.listeners[name] or {}) do
    local ok, err = pcall(fn, data)
    if not ok then
      self:log("[表现层回调出错] %s: %s", tostring(name), tostring(err))
    end
  end
end

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
  -- 【奋迅】：本回合与指定角色的距离固定为 1
  if a.fixed_distance and a.fixed_distance[b] then return a.fixed_distance[b] end
  local n = #self.players
  local d = math.abs(a.seat - b.seat)
  d = math.min(d, n - d)
  -- 进攻马 -1、防御马 +1、技能标记（如【马术】-1）；最低为 1
  local skill_mod = Generals.marker(a, "distance_mod", 0) or 0
  local dist = d + (a:distanceModifier() or 0) + (b:defenseModifier() or 0) + skill_mod
  -- 兼容层的 DistanceSkill：correct_func 返回修正值（原版是方法，故用冒号调用）
  for _, s in ipairs(self:skillsOf(a)) do
    if type(s.distance_correct) == "function" then
      dist = dist + (s:distance_correct(a, b) or 0)
    end
  end
  if dist < 1 then dist = 1 end
  return dist
end

-- 攻击范围：武器基础值 + 兼容层 AttackRangeSkill 的 extra_func
function Room:attackRangeOf(p)
  local base = p:attackRange()
  for _, s in ipairs(self:skillsOf(p)) do
    if type(s.attack_range_extra) == "function" then
      base = base + (s:attack_range_extra(p) or 0)
    end
  end
  return base
end

-- 手牌上限：默认等于体力；兼容层 MaxCardsSkill 可修正
function Room:maxCards(p)
  local n = math.max(p.hp, 0)
  for _, s in ipairs(self:skillsOf(p)) do
    if type(s.max_cards_fixed) == "function" then
      local fixed = s:max_cards_fixed(p)
      if type(fixed) == "number" then return fixed end
    end
    if type(s.max_cards_extra) == "function" then
      n = n + (s:max_cards_extra(p) or 0)
    end
  end
  return n
end

-- 出【杀】的次数上限：默认 1，兼容层 TargetModSkill 的 residue_func 可增加
function Room:slashLimit(p)
  local n = 1
  for _, s in ipairs(self:skillsOf(p)) do
    if type(s.target_residue) == "function" then
      n = n + (s:target_residue(p, nil) or 0)
    end
  end
  return n
end

-- 是否可额外指定目标（兼容层 TargetModSkill 的 extra_target_func）
function Room:extraTargets(p, card)
  local n = 0
  for _, s in ipairs(self:skillsOf(p)) do
    if type(s.target_extra) == "function" then
      n = n + (s:target_extra(p, card) or 0)
    end
  end
  return n
end

-- 目标距离限制的放宽量（兼容层 TargetModSkill 的 distance_limit_func）
function Room:distanceLimitBonus(p, card)
  local n = 0
  for _, s in ipairs(self:skillsOf(p)) do
    if type(s.target_distance_limit) == "function" then
      n = n + (s:target_distance_limit(p, card) or 0)
    end
  end
  return n
end

-- 禁止技能（ProhibitSkill）：任意角色的该技能都可禁止某次指定
function Room:isProhibited(from, to, card)
  for _, p in ipairs(self.players) do
    for _, s in ipairs(self:skillsOf(p)) do
      if type(s.prohibit) == "function" then
        local ok, blocked = pcall(s.prohibit, s, from, to, card)
        if ok and blocked then return true end
      end
    end
  end
  return false
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
-- 签名兼容两种写法：本引擎 room:throwCard(who, card)，
-- 原版 room:throwCard(card, who) —— 第一个参数是 Card 时按原版顺序处理。
function Room:throwCard(a, b)
  local card = (type(a) == "table" and a.name and a.ctype) and a or b
  if card then table.insert(self.discardPile, card) end
end

-- 从弃牌堆取回一张牌（【奸雄】等技能用）
function Room:takeFromDiscard(card)
  for i, c in ipairs(self.discardPile) do
    if c == card then return table.remove(self.discardPile, i) end
  end
  return nil
end

-- 免疫【南蛮入侵】：藤甲，或技能标记（【祸首】/【巨象】）
function Room:isSavageImmune(p)
  if p:hasEquip("vine") then return true end
  return Generals.marker(p, "savage_immune", false) == true
end

-- 找出能把某张手牌「当作」want_name 使用的转化技，返回 {skill, card} 列表
function Room:viewAsCandidates(p, want_name)
  local out = {}
  local skills = {}
  for _, s in ipairs((p.general and p.general.skills) or {}) do table.insert(skills, s) end
  for _, s in ipairs(p.extra_skills or {}) do table.insert(skills, s) end
  for _, s in ipairs(skills) do
    -- 【急救】：只能在自己回合外发动
    if s.only_outside_turn and p.phase ~= "not_active" then
      -- 自己的回合内不可用
    elseif s.result_name == nil and s.view_as then
      -- DIY 扩展的动态转化技：结果牌名不固定（如【神偷】梅花→顺手牵羊），
      -- 只能逐张试算看能变成什么
      for _, c in ipairs(p.hand) do
        -- 试算前同样要走过滤条件，否则任意牌都能「转化」
        if (not s.filter or s:filter(c, p)) then
          local made = s:view_as({ c })
          if made and made.name == want_name then
            table.insert(out, { skill = s, card = c })
          end
        end
      end
    elseif s.result_name ~= want_name then
      -- 不匹配
    elseif s.n == 2 and s.filter_pair then
      -- 双牌转化技（【乱击】两张同花色当【万箭齐发】）
      for i = 1, #p.hand do
        for j = i + 1, #p.hand do
          if s:filter_pair(p.hand[i], p.hand[j], p) then
            table.insert(out, { skill = s, card = p.hand[i], card2 = p.hand[j] })
            return out
          end
        end
      end
    elseif s.filter then
      -- filter 需要知道持有者（【双雄】按本回合判定色过滤），故把 p 传进去
      for _, c in ipairs(p.hand) do
        if s:filter(c, p) then table.insert(out, { skill = s, card = c }) end
      end
    end
  end
  return out
end

-- 用转化技把 card 变成目标牌（返回虚拟牌或 nil）
function Room:viewAsCard(p, want_name, card)
  for _, item in ipairs(self:viewAsCandidates(p, want_name)) do
    if item.card == card then
      local made = item.skill:view_as({ card })
      if made then return made end
    end
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
    if p.alive then
      if p.turned_over then
        -- 翻面：跳过整个回合并翻回正面（【放逐】【据守】等）
        p.turned_over = false
        self:log("%s 处于翻面状态，跳过整个回合", p.name)
        self:trigger("TurnedOver", p, { player = p })
      else
        self:_turn(p)
      end
    end
    if self:_checkStall() then break end
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
  if p.skipped and p.skipped[name] then
    self:log("%s 跳过%s阶段", p.name, Room.PHASE_ZH[name] or name)
    return
  end
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
  local excess = #p.hand - self:maxCards(p)
  if excess <= 0 then return end
  local discarded = self:askForDiscard(p, excess)
  local n = 0
  -- 记录本次弃牌，供【固政】在弃牌阶段结束时取用
  self.last_discard_player, self.last_discarded = p, {}
  for _, c in ipairs(discarded or {}) do
    if p:takeCard(c) then
      table.insert(self.discardPile, c)
      table.insert(self.last_discarded, c)
      n = n + 1
    end
  end
  if n > 0 then self:log("%s 弃置 %d 张牌", p.name, n) end
  -- 失去最后一张手牌：【死谏】的挂载点
  if #p.hand == 0 then
    self:trigger("CardsMoveOneTime", p,
      { player = p, from_place = "hand", last_handcard = true })
  end
end

function Room:_phase_finish(_p)
end

-- ===== 判定 =====

-- 过滤技（FilterSkill）的统一花色入口。
-- 原版里【红颜】这类过滤技会改写牌的花色，影响所有花色判定；
-- 本引擎此前只把它当成标记，只对技能自身生效，判定区/雷击等处都不认。
--
-- 约定：技能提供 filter_view_filter(card) -> bool 与 filter_view(card) -> 花色或牌。
-- 任何「看花色」的地方都应走这里，而不是直接读 card.suit。
function Room:effSuit(p, card)
  if not card then return nil end
  if not p then return card.suit end
  for _, s in ipairs(self:skillsOf(p)) do
    -- 注意用点号调用：过滤函数是「只接 card」的普通函数，
    -- 用冒号会把技能自身当成第一个参数传进去
    if s.filter_view_filter and s.filter_view_filter(card) then
      local made = s.filter_view and s.filter_view(card)
      if type(made) == "number" then return made end       -- 直接给花色
      if type(made) == "table" and made.suit then return made.suit end -- 给了张牌
    end
  end
  return card.suit
end

-- 玩家身上生效的全部技能（武将技 + 临时获得的）
function Room:skillsOf(p)
  local out = {}
  if not p then return out end
  for _, s in ipairs((p.general and p.general.skills) or {}) do
    table.insert(out, s)
  end
  for _, s in ipairs(p.extra_skills or {}) do table.insert(out, s) end
  return out
end

-- 判定牌的「有效花色」：走过滤技，让【红颜】这类技能真正影响判定结果
function Room:judgeSuit(p, judge_card)
  return self:effSuit(p, judge_card)
end

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

  self:trigger("StartJudge", p, { player = p, card = card, judge_card = judge_card })

  -- 改判：技能（【鬼才】等）可把判定牌替换为一张手牌，被替换的旧判定牌进弃牌堆
  local retrial = { player = p, card = card, judge_card = judge_card, reason = card.name }
  if self:trigger("AskForRetrial", p, retrial) and retrial.judge_card ~= judge_card then
    -- 被替换下来的旧判定牌在这里才入弃牌堆。技能若想获得它（【鬼道】），
    -- 必须置 obtain_old/replacer 由引擎代劳——技能在触发回调里直接 obtain
    -- 会拿不到（此时牌还没进弃牌堆），反而造成一张牌被登记两次。
    if retrial.obtain_old and retrial.replacer then
      table.insert(retrial.replacer.hand, judge_card)
    else
      table.insert(self.discardPile, judge_card)
    end
    judge_card = retrial.judge_card
  end

  local def = Cards.get(card.name)
  local result = false
  if def and def.judge then
    result = def.judge(self, p, judge_card) == true
  end
  table.insert(self.discardPile, judge_card)
  self:trigger("FinishJudge", p, {
    player = p, card = card, judge_card = judge_card, result = result,
  })

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

  -- 转化技产生的虚拟牌：实体牌仍以 subcards 形式留在手中，需逐一取出
  local is_virtual = card ~= nil and card.virtual == true
  if not card then return false end
  if is_virtual then
    local got = 0
    for _, sc in ipairs(card.subcards or {}) do
      if from:takeCard(sc) then got = got + 1 end
    end
    -- phantom：技能凭空生成的牌（【神速】等），无实体来源，允许 subcards 为空
    if got == 0 and not card.phantom then
      self:log("%s 的转化牌来源已不在手牌中，忽略", from.name)
      return false
    end
  elseif not from:takeCard(card) then
    self:log("%s 的响应包含不在手牌中的卡，忽略", from.name)
    return false
  end

  local use = { from = from, card = card, to = targets }
  local def = Cards.get(card.name)

  -- AOE 类锦囊的作用目标由引擎展开，BOT/UI 只需指定卡牌本身
  if def and def.target == "all_other" then
    targets = self:otherAlivePlayers(from)
    use.to = targets
  elseif def and def.target == "all" then
    targets = self:alivePlayers()
    use.to = targets
  end

  if self:trigger("PreCardUsed", from, use) then
    self:_refund(from, card)
    self:log("【%s】的使用被取消", card:zhName())
    return false
  end

  -- 合法性校验（不合法则退还）
  if not self:_validateUse(from, card, targets) then
    self:_refund(from, card)
    return false
  end

  -- 技能牌（原版 SkillCard）：效果写在 skill_card 的 on_use / on_effect 里。
  -- 必须在卡牌分派之前拦下——否则查不到卡牌定义，会落进「暂无结算规则」兜底。
  if card.skill_card then
    return self:_useSkillCard(from, card, use)
  end

  self:emit("useCard", { card = card, from = from, to = use.to })
  self:trigger("CardUsed", from, use)
  -- 目标确认中：【流离】在此把【杀】转移给攻击范围内的另一名角色
  self:trigger("TargetConfirming", use.to[1], use)
  -- 指定目标后触发：【铁骑】【烈弓】等在此决定此牌可否被闪避
  self:trigger("TargetChosen", from, use)

  -- 锦囊（含延时锦囊）可被【无懈可击】抵消
  if def and def.nullifiable and self:askForNullification(use) then
    self:_toDiscard(card)
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
    self:_toDiscard(card)
    self:trigger("CardEffect", from, use)
    def.effect(self, use)
    self:trigger("CardFinished", from, use)
    return true
  end

  -- 用 use.to 而非局部变量 targets：目标可能在 TargetConfirming 被【流离】改过
  return self:_useBasic(from, card, use.to)
end

-- 退还：虚拟牌要把实体牌还给使用者
function Room:_refund(p, card)
  if card.virtual then
    for _, sc in ipairs(card.subcards or {}) do table.insert(p.hand, sc) end
  else
    table.insert(p.hand, card)
  end
end

-- 入弃牌堆：虚拟牌丢弃其实体牌（除非效果已另行处理）
function Room:_toDiscard(card)
  if card.virtual then
    if not card.sub_consumed then
      for _, sc in ipairs(card.subcards or {}) do table.insert(self.discardPile, sc) end
    end
  else
    table.insert(self.discardPile, card)
  end
end

-- 基本牌结算：杀 / 桃 / 酒
function Room:_useBasic(from, card, targets)
  local name = card.name

  if name == "slash" or name == "fire_slash" or name == "thunder_slash" then
    local target = targets[1]
    if from.slash_count >= self:slashLimit(from) and not self:allowsUnlimitedSlash(from) then
      self:log("%s 本回合已使用过【杀】，退还", from.name)
      self:_refund(from, card)
      return false
    end
    if not target or target == from or not target.alive then
      self:log("【杀】的目标非法，退还")
      self:_refund(from, card)
      return false
    end
    -- 【天义】拼点失利：本回合不能使用【杀】
    if Generals.marker(from, "no_slash", false) then
      self:log("%s 本回合不能使用【杀】，退还", from.name)
      self:_refund(from, card)
      return false
    end
    -- 【神速】/【天义】等生成的【杀】无视距离
    local far = Generals.marker(from, "slash_no_distance", false)
    local reach = self:attackRangeOf(from) + self:distanceLimitBonus(from, card)
    if not (card.no_distance_limit or far) and self:distance(from, target) > reach then
      self:log("目标不在攻击范围内（距离 %d > 范围 %d），退还",
        self:distance(from, target), from:attackRange())
      self:_refund(from, card)
      return false
    end
    from.slash_used = true
    from.slash_count = from.slash_count + 1
    self:_toDiscard(card)
    self:_resolveSlash(from, target, card)

    -- 【短兵】（锁定技）：此【杀】可额外指定一名距离 1 以内的角色
    if Generals.marker(from, "slash_extra_target", false) then
      for _, q in ipairs(self.players) do
        if q ~= from and q ~= target and q.alive and self:distance(from, q) <= 1 then
          self:log("%s 的【短兵】生效，【杀】额外指定 %s", from.name, q.name)
          self:_resolveSlash(from, q, card)
          break
        end
      end
    end
    return true

  elseif name == "peach" then
    if from.hp >= from.max_hp then
      self:log("%s 体力已满，不能使用【桃】，退还", from.name)
      self:_refund(from, card)
      return false
    end
    self:_toDiscard(card)
    self:log("%s 使用【桃】", from.name)
    self:heal(from, 1)
    return true

  elseif name == "analeptic" then
    if from.hp < from.max_hp then
      self:_toDiscard(card)
      self:log("%s 濒死时使用【酒】回复体力", from.name)
      self:heal(from, 1)
    else
      from.drunk = true
      self:_toDiscard(card)
      self:log("%s 饮酒，下一张【杀】伤害 +1", from.name)
    end
    return true

  elseif name == "dodge" then
    -- 【闪】不能主动使用
    self:log("【闪】不能主动使用，退还")
    self:_refund(from, card)
    return false
  end

  self:log("%s 打出 %s（暂无结算规则）", from.name, card:zhName())
  self:_toDiscard(card)
  return true
end

function Room:_validateUse(from, card, targets)
  local def = Cards.get(card.name)
  if not def then return true end

  -- 禁止技（兼容层 ProhibitSkill / 原版 isProhibited）：任一角色的该技能
  -- 都可禁止这次指定
  for _, t in ipairs(targets or {}) do
    if t and self:isProhibited(from, t, card) then
      self:log("对 %s 的使用被禁止技拦下", t.name)
      return false
    end
  end

  -- 【奇才】：使用锦囊牌无视距离限制
  local ignore_range = Generals.marker(from, "no_trick_range", false)
  if def.distance and not (ignore_range and def.ctype == Card.Type.Trick) then
    local t = targets[1]
    -- 逐牌名叠加距离加成：【断粮】使用【兵粮寸断】时距离 +1
    -- 兼容层 TargetModSkill 的 distance_limit_func 也可放宽距离限制
    local limit = def.distance + Generals.marker(from, "extra_dist_" .. card.name, 0)
      + self:distanceLimitBonus(from, card)
    if t and self:distance(from, t) > limit then
      self:log("目标超出【%s】的距离限制（%d > %d），退还",
        card:zhName(), self:distance(from, t), limit)
      return false
    end
  end

  if def.target == "none" then return true end
  if #targets == 0 and def.target ~= "self" then
    self:log("【%s】需要目标，退还", card:zhName())
    return false
  end

  -- 【帷幕】（锁定技）：不能成为黑色锦囊牌的目标
  for _, t in ipairs(targets) do
    if t and Generals.marker(t, "no_black_trick", false) and def.ctype == Card.Type.Trick
      and not card:isRed() then
      self:log("%s 的【帷幕】生效，不能成为黑色锦囊【%s】的目标", t.name, card:zhName())
      return false
    end
  end

  -- 【谦逊】（锁定技）：不能成为指定锦囊（【顺手牵羊】【乐不思蜀】）的目标
  for _, t in ipairs(targets) do
    local banned = t and Generals.marker(t, "no_target_tricks", nil)
    if banned and def.ctype == Card.Type.Trick and banned[card.name] then
      self:log("%s 的【谦逊】生效，不能成为【%s】的目标", t.name, card:zhName())
      return false
    end
  end

  -- 【空城】（锁定技）：没有手牌时不能成为【杀】/【决斗】的目标
  for _, t in ipairs(targets) do
    if t and Generals.marker(t, "no_target_empty", false) and #t.hand == 0 then
      if card.name == "slash" or card.name == "fire_slash"
        or card.name == "thunder_slash" or card.name == "duel" then
        self:log("%s 发动【空城】，无手牌时不能成为此牌的目标", t.name)
        return false
      end
    end
  end
  return true
end

-- 装备：旧装备进弃牌堆；白银狮子失去时回血
function Room:_equipCard(from, card)
  local def = Cards.get(card.name)
  local slot = def and def.equip or "weapon"
  local old = from:equipCard(card, slot)
  if old then
    self:_onEquipLost(from, old)
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

  -- 【享乐】（锁定技）：体力大于 1 时成为【杀】的目标，使用者需弃一张牌，否则此【杀】无效
  if Generals.marker(to, "xiangle", false) and to.hp > 1 and #from.hand > 0 then
    self:log("%s 的【享乐】生效：%s 需弃置一张牌，否则此【杀】无效", to.name, from.name)
    local dumped = self:askForDiscardFrom(to, from, 1)
    if not dumped then
      self:log("%s 未能弃牌，此【杀】无效", from.name)
      self:trigger("SlashMissed", to, { from = from, to = to })
      return
    end
  end

  -- 【铁骑】/【烈弓】：此【杀】不可被【闪】响应
  if card.cannot_dodge then
    self:log("此【杀】不可被【闪】响应")
    self:_slashHit(from, to, card, nature, ignore_armor)
    return
  end

  local dodged = false
  local dodge = self:askForCard(to, "dodge",
    string.format("%s 对你使用【%s】，请打出【闪】", from.name, card:zhName()))
  if dodge and dodge.name == "dodge" and to:takeCard(dodge) then
    dodged = true
    table.insert(self.discardPile, dodge)
    self:log("%s 打出【闪】", to.name)
    self:trigger("CardResponded", to, { player = to, card = dodge })
  end

  -- 【无双】（锁定技）：吕布的【杀】需两张【闪】才能抵消
  if dodged and Generals.marker(from, "wushuang", false) then
    local d2 = self:askForCard(to, "dodge", "【无双】：需再打出一张【闪】")
    if d2 and d2.name == "dodge" and to:takeCard(d2) then
      table.insert(self.discardPile, d2)
      self:log("%s 再打出一张【闪】", to.name)
      self:trigger("CardResponded", to, { player = to, card = d2 })
    else
      dodged = false
      self:log("%s 无法再打出【闪】，【杀】命中", to.name)
    end
  end

  -- 八卦阵：未打出【闪】时可判定，红色视为打出【闪】
  -- 【八阵】：没装备防具时视为装备着【八卦阵】
  local auto_armor = Generals.marker(to, "auto_armor", nil)
  local has_bagua = to:hasEquip("eight_diagram") ~= nil
    or (auto_armor == "eight_diagram" and to:getArmor() == nil)
  if not dodged and has_bagua and not ignore_armor then
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

  self:_slashHit(from, to, card, nature, ignore_armor)
end

-- 【杀】命中后的伤害与后续效果
function Room:_slashHit(from, to, card, nature, ignore_armor)
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
        self:_onEquipLost(to, horse)
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
  self:emit("damage", { to = to, from = from, n = data.n, nature = data.nature })
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

-- 失去体力（【强袭】等）：不走伤害管线，直接扣血并进入濒死结算
function Room:loseHp(p, n)
  n = n or 1
  p.hp = p.hp - n
  self:log("%s 失去 %d 点体力（剩 %d）", p.name, n, math.max(p.hp, 0))
  if p.hp <= 0 then
    p.hp = 0
    self:_dying(p, nil)
  end
end

-- ===== 技能常用原语 =====

-- 跳过 p 本回合的某个阶段（【巧变】【神速】等）
function Room:skipPhase(p, name)
  p.skipped = p.skipped or {}
  p.skipped[name] = true
end

-- 翻面（【据守】【放逐】）：翻面角色跳过下一个回合
function Room:turnOver(p)
  p.turned_over = not p.turned_over
  self:log("%s %s", p.name, p.turned_over and "被翻面（将跳过下一回合）" or "翻回正面")
end

-- 把一张牌收入某角色手牌：先从原区域摘除，再进手牌
-- card 通常来自弃牌堆或他人手牌（【奸雄】【行殇】【反馈】）
function Room:obtain(p, card)
  if not card then return false end
  -- 凭空生成的牌（【神速】等 phantom）没有实体，收进手牌就会凭空多出一张。
  -- 曾导致【奸雄】把神速的虚拟杀收走，压测报「卡牌不守恒 119 != 118」。
  if card.phantom then return false end
  if card.virtual and not (card.subcards and card.subcards[1]) then return false end
  for i, c in ipairs(self.discardPile) do
    if c == card then table.remove(self.discardPile, i) break end
  end
  for _, q in ipairs(self.players) do
    if q ~= p and q:takeCard(card) then break end
  end
  if p:hasEquip(card.name) == card then p:unequipCard(card) end
  table.insert(p.hand, card)
  return true
end

-- 技能牌结算（原版 SkillCard）
-- will_throw 默认为 true：作为代价选中的牌先入弃牌堆，再执行 on_use。
-- on_use 若被重写则由它自己处理目标；否则对每个目标调 on_effect。
function Room:_useSkillCard(from, card, use)
  local sc = card.skill_card
  -- 供兼容层在回调里取 sgs.Self / sgs.CurrentRoom（core 不依赖 compat）
  card.__user, card.__room = from, self
  local targets = {}
  for _, t in ipairs(use.to or {}) do
    if t and t.alive then table.insert(targets, t) end
  end

  if sc.will_throw ~= false then
    for _, c in ipairs(card.subcards or {}) do table.insert(self.discardPile, c) end
  end

  self:log("%s 发动技能牌【%s】", from.name, sc.name or card.name)

  local ok, err
  if sc.on_use then
    ok, err = pcall(sc.on_use, card, self, from, targets)
  else
    ok, err = true, nil
    for _, t in ipairs(targets) do
      if sc.on_effect then
        ok, err = pcall(sc.on_effect, card, { card = card, from = from, to = t })
        if not ok then break end
      end
    end
  end
  if not ok then
    error(string.format("[兼容层] 技能牌 %s 结算出错: %s",
      tostring(sc.name), tostring(err)), 0)
  end
  return true
end

-- 失去装备区的一张牌（【枭姬】的挂载点）
function Room:_onEquipLost(p, card)
  self:trigger("CardsMoveOneTime", p, { player = p, card = card, from_place = "equip" })
end

-- 拼点：双方各出一张手牌比点数，点数大者胜（平局算发起方负）；两张牌均弃置
function Room:pindian(a, b)
  if #a.hand == 0 or #b.hand == 0 then return false end
  local ca, cb = a.hand[1], b.hand[1]
  a:takeCard(ca)
  b:takeCard(cb)
  table.insert(self.discardPile, ca)
  table.insert(self.discardPile, cb)
  self:log("拼点：%s %s%d vs %s %s%d", a.name, ca:suitString(), ca.number,
    b.name, cb:suitString(), cb.number)
  return ca.number > cb.number
end

-- 从 victim 的手牌/装备中抽走一张给 from（【反馈】等）
function Room:takeOneCard(from, victim)
  if #victim.hand > 0 then
    local c = victim.hand[1]
    victim:takeCard(c)
    table.insert(from.hand, c)
    self:log("%s 获得 %s 的一张手牌", from.name, victim.name)
    return c
  end
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    local e = victim.equips[slot]
    if e then
      victim.equips[slot] = nil
      table.insert(from.hand, e)
      self:log("%s 获得 %s 的【%s】", from.name, victim.name, e:zhName())
      return e
    end
  end
  return nil
end

function Room:_dying(p, killer)
  -- 技能可截断濒死结算：【涅槃】放弃求桃直接回满，【不屈】翻出「创」牌免死
  if self:trigger("Dying", p, { player = p }) then
    self:trigger("QuitDying", p, { player = p })
    return
  end
  -- 【完杀】（锁定技）：贾诩的回合内，只有他自己才能用【桃】救人
  local turner = self.players[self.current_seat]
  if turner and turner ~= p and Generals.marker(turner, "wansha", false) then
    self:log("%s 的【完杀】生效：%s 的回合内他人无法使用【桃】救援", turner.name, turner.name)
    self:_kill(p, killer)
    return
  end

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
  self:trigger("Death", p, { player = p, killer = killer }) -- 【断肠】需要凶手
  self:emit("death", { player = p, killer = killer })
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
