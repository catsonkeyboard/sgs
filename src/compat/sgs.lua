-- sgs.* 兼容层：让原版 QSanguosha 的 DIY 扩展脚本能直接跑起来
--
-- 设计取舍（重要）：
--   1) 事件/频率常量直接用**字符串**，取值就是本引擎 TriggerEvent / Frequency 的值。
--      这样 `events = { sgs.Damaged }` 写进来的就是 { "Damaged" }，
--      无需任何转换即可进入 `Room:trigger` 的管线。
--   2) 技能工厂产出的对象直接是 `core/skill.lua` 的 TriggerSkill / ViewAsSkill，
--      不另建一套类型，避免两条技能体系并存。
--   3) data 用 QVariant 包一层，所有 toXxx() 都返回同一个底层表
--      （本引擎的伤害/用牌结构本来就是普通表），因此脚本的读写直接生效。
--
-- 未实现（原版有但本引擎暂无对应机制）：鸡肋、明置/暗置武将、国战势力结盟、
-- 阵法技、兵符。遇到相关字段会被安全忽略。
local Card = require "src.core.card"
local Cards = require "src.core.cards"
local sk = require "src.core.skill"
local ExpPattern = require "src.compat.exppattern"
require "src.compat.api" -- 安装 Room/Player/Card 的原版 API 别名

local TriggerSkill = sk.TriggerSkill
local ViewAsSkill = sk.ViewAsSkill
local TriggerEvent = sk.TriggerEvent
local Frequency = sk.Frequency

local sgs = {}

-- ===== 常量 =====

-- 触发事件：直接复用引擎的事件名字符串
sgs.TriggerEvent = TriggerEvent
for k, v in pairs(TriggerEvent) do sgs[k] = v end

-- 技能频率
sgs.Skill_NotFrequent = Frequency.NotFrequent
sgs.Skill_Frequent = "Frequent"
sgs.Skill_Compulsory = Frequency.Compulsory
sgs.Skill_Limited = Frequency.Limited
sgs.Skill_Wake = Frequency.Wake

-- 花色（沿用引擎编号；SuitToBeDecided 无对应，退化为无花色）
sgs.Card_SuitToBeDecided = -1
sgs.Card_NoSuit = Card.Suit.NoSuit
sgs.Card_Spade = Card.Suit.Spade
sgs.Card_Heart = Card.Suit.Heart
sgs.Card_Club = Card.Suit.Club
sgs.Card_Diamond = Card.Suit.Diamond

-- 扩展包类型
sgs.Package_GeneralPack = 1
sgs.Package_CardPack = 2

-- 装备位置（原版 EquipCard::Location）
sgs.EquipCard_WeaponLocation = 0
sgs.EquipCard_ArmorLocation = 1
sgs.EquipCard_DefensiveHorseLocation = 2
sgs.EquipCard_OffensiveHorseLocation = 3
sgs.EquipCard_TreasureLocation = 4

-- 伤害属性
sgs.DamageStruct_Normal = "normal"
sgs.DamageStruct_Fire = "fire"
sgs.DamageStruct_Thunder = "thunder"

-- 卡牌区域（原版 Player::Place），值沿用引擎的字符串
sgs.Player_Hand = "hand"
sgs.Player_Equip = "equip"
sgs.Player_Judge = "judge"
sgs.Player_DiscardPile = "discardPile"
sgs.Player_DrawPile = "drawPile"
sgs.Player_PlaceTable = "table"
sgs.Player_PlaceSpecial = "special"

-- 回合阶段（原版 Player::Phase）
sgs.Player_RoundStart = "round_start"
sgs.Player_Start = "start"
sgs.Player_Judge = "judge"
sgs.Player_Draw = "draw"
sgs.Player_Play = "play"
sgs.Player_Discard = "discard"
sgs.Player_Finish = "finish"
sgs.Player_NotActive = "not_active"

-- 卡牌操作方式（原版 Card::HandlingMethod）
sgs.Card_MethodUse = "use"
sgs.Card_MethodResponse = "response"
sgs.Card_MethodDiscard = "discard"
sgs.Card_MethodRecast = "recast"
sgs.Card_MethodPindian = "pindian"

-- 原版的 **bot 提示表**（名字沿用原版 API 的 sgs.ai_*，不能改，
-- 否则 DIY 脚本塞值时就崩了）。它们描述的是原版那个规则驱动的脚本对手
-- 如何使用技能，与本引擎的 src/core/bot.lua 是两套东西。
-- 本引擎的 BOT 不消费这些表（走 CONVERT_TARGETS + 试算），这里只为兼容。
sgs.ai_view_as = {}
sgs.ai_filterskill_filter = {}
sgs.ai_skill_invoke = {}
sgs.ai_skill_use = {}
sgs.ai_skill_playerchosen = {}
sgs.ai_skill_cardask = {}
sgs.ai_skill_choice = {}
sgs.ai_cardshow = {}
sgs.ai_chaofeng = {}

-- 原版牌名 -> 本引擎牌名（只列命名不一致的）
local CARD_ALIAS = {
  jink = "dodge", analeptic = "analeptic", slash = "slash",
  fire_slash = "fire_slash", thunder_slash = "thunder_slash",
}

-- 中文翻译表
sgs.Translations = {}

function sgs.LoadTranslationTable(t)
  for k, v in pairs(t or {}) do
    sgs.Translations[k] = v
    -- 卡牌/技能的中文名也喂给引擎的显示映射
    if Cards.get(k) then Card.ZH[k] = v end
  end
end

-- ===== QVariant =====
-- toXxx() 一律返回底层表本身（本引擎的伤害/用牌/判定结构就是普通表），
-- 因此脚本的读改写会直接作用到真实数据上。

local QVariant = {}
QVariant.__name = "QVariant"

-- 读写都穿透到底层表：脚本 `data.n = n` 要能真正改到引擎的数据上
QVariant.__index = function(t, k)
  if QVariant[k] ~= nil then return QVariant[k] end
  local v = rawget(t, "__qv")
  return v and v[k]
end
QVariant.__newindex = function(t, k, val)
  local v = rawget(t, "__qv")
  if v then v[k] = val end
end

function sgs.QVariant(v)
  return setmetatable({ __qv = v or {} }, QVariant)
end

function QVariant:toDamage() return self.__qv end
function QVariant:toCardUse() return self.__qv end
function QVariant:toDying() return self.__qv end
function QVariant:toCardResponse() return self.__qv end
function QVariant:toCard() return self.__qv.card end
function QVariant:toPlayer() return self.__qv.player or self.__qv end
function QVariant:toInt() return self.__qv.n or 0 end
function QVariant:toString() return tostring(self.__qv) end
function QVariant:toBool() return self.__qv == true end
function QVariant:isNull() return self.__qv == nil end
function QVariant:setValue(v) self.__qv = v end
-- 判定结构：本引擎用 {player, card, judge_card, result, reason}
function QVariant:toJudge()
  local j = self.__qv
  return {
    who = j.player, card = j.judge_card, reason = j.reason,
    pattern = j.pattern, is_good = j.result,
  }
end

-- ===== Package / General =====

function sgs.Package(name, ptype)
  local pkg = {
    __package = true,
    name = name or "diy",
    ptype = ptype or sgs.Package_GeneralPack,
    generals = {},
    cards = {},
  }
  sgs.Packages = sgs.Packages or {}
  table.insert(sgs.Packages, pkg)
  return pkg
end

-- sgs.General(package, name, kingdom, max_hp, male, hidden, ...)
function sgs.General(pkg, name, kingdom, max_hp, male, _hidden)
  local g = {
    __general = true,
    name = name,
    key = name,
    kingdom = kingdom or "qun",
    max_hp = max_hp or 4,
    female = (male == false),
    skills = {},
    companions = {},
  }
  function g:addSkill(skill)
    if not skill then return end
    table.insert(g.skills, skill)
    -- 触发技挂着的转化技要一并登记，否则引擎看不到
    if skill.view_as_skill then table.insert(g.skills, skill.view_as_skill) end
    return self
  end
  function g:addCompanion(n)
    table.insert(g.companions, n)
    return self
  end
  function g:getSkillName() return g.name end
  if pkg and pkg.generals then table.insert(pkg.generals, g) end
  return g
end

-- ===== 技能工厂 =====

-- 把原版回调包一层：注入 event / QVariant 化的 data / sgs.Self
local function wrapCallbacks(spec)
  local function call(fn, self, ev, room, player, data)
    if not fn then return nil end
    local prev, prev_room = sgs.Self, sgs.CurrentRoom
    sgs.Self = player
    sgs.CurrentRoom = room -- player:drawCards() 等需要反查房间
    local ok, res = pcall(fn, self, ev, room, player, sgs.QVariant(data))
    sgs.Self = prev
    sgs.CurrentRoom = prev_room
    if not ok then
      error(string.format("[sgs 兼容层] 技能 %s 回调出错: %s", tostring(spec.name), tostring(res)), 0)
    end
    return res
  end
  return call
end

function sgs.CreateTriggerSkill(spec)
  assert(type(spec.name) == "string", "CreateTriggerSkill 需要 name")
  local events = {}
  if type(spec.events) == "string" then
    events = { spec.events }
  elseif type(spec.events) == "table" then
    events = spec.events
  end
  local call = wrapCallbacks(spec)

  local s = TriggerSkill.create(spec.name, events, function(self, room, player, data)
    local ev = data and data.event
    -- can_trigger 返回 true/false；原版还可返回 (bool, 目标玩家)，这里忽略目标
    if spec.can_trigger then
      if not call(spec.can_trigger, self, ev, room, player, data) then return false end
    end
    if spec.on_cost then
      if not call(spec.on_cost, self, ev, room, player, data) then return false end
    end
    if spec.on_effect then
      return call(spec.on_effect, self, ev, room, player, data) == true
    end
    return false
  end, {
    zh = spec.name,
    frequency = spec.frequency or Frequency.NotFrequent,
    priority = spec.priority,
  })

  s.__spec = spec
  if spec.view_as_skill then s.view_as_skill = spec.view_as_skill end
  return s
end

-- 原版专用包装：只关心 on_damaged（受伤后）
function sgs.CreateMasochismSkill(spec)
  return sgs.CreateTriggerSkill({
    name = spec.name,
    frequency = spec.frequency,
    events = { TriggerEvent.Damaged },
    can_trigger = spec.can_trigger,
    on_cost = spec.on_cost,
    on_effect = function(self, event, room, player, data)
      return spec.on_damaged(self, player, data:toDamage()) ~= false
    end,
  })
end

-- 原版专用包装：回合阶段变化时触发
function sgs.CreatePhaseChangeSkill(spec)
  return sgs.CreateTriggerSkill({
    name = spec.name,
    frequency = spec.frequency,
    events = { TriggerEvent.EventPhaseStart },
    can_trigger = spec.can_trigger,
    on_cost = spec.on_cost,
    on_effect = function(self, event, room, player, data)
      -- 原版 on_phasechange 返回 true 表示跳过后续阶段处理
      return spec.on_phasechange(self, player) == true
    end,
  })
end

-- 原版专用包装：摸牌阶段调整摸牌数
function sgs.CreateDrawCardsSkill(spec)
  return sgs.CreateTriggerSkill({
    name = spec.name,
    frequency = spec.frequency,
    events = { TriggerEvent.DrawNCards },
    on_effect = function(self, event, room, player, data)
      local n = spec.draw_num_func(self, player, data:toInt() or 2)
      data.n = n
      return false
    end,
  })
end

-- 通用 ViewAsSkill
local function makeViewAsSkill(spec, kind)
  local s = ViewAsSkill.create(spec.name, { zh = spec.name, n = (kind == "zero") and 0 or 1 })
  s.__spec = spec
  s.dynamic = true -- 结果牌名不固定，BOT 需要试算

  function s:filter(c, p)
    if kind == "zero" then return false end
    if spec.view_filter then
      return spec.view_filter(self, {}, c) == true
    end
    if spec.filter_pattern then
      return ExpPattern.match(spec.filter_pattern, c, "hand")
    end
    return false
  end

  function s:view_as(cards)
    cards = cards or {}
    -- 让 Card:addSubcard(id) 能把 id 还原成真正的牌对象
    require "src.compat.api".setCurrentSubcards(cards)
    if kind == "one" then
      if #cards ~= 1 then return nil end
      return spec.view_as(self, cards[1])
    elseif kind == "zero" then
      if #cards > 0 then return nil end
      return spec.view_as(self)
    end
    return spec.view_as(self, cards)
  end

  s.enabled_at_play = spec.enabled_at_play
  s.enabled_at_response = spec.enabled_at_response
  return s
end

function sgs.CreateViewAsSkill(spec) return makeViewAsSkill(spec, "multi") end
function sgs.CreateOneCardViewAsSkill(spec) return makeViewAsSkill(spec, "one") end
function sgs.CreateZeroCardViewAsSkill(spec) return makeViewAsSkill(spec, "zero") end

-- 原版距离/手牌上限/目标调整类技能：登记为标记技，由引擎查询
local function markerSpec(spec, fields)
  local s = TriggerSkill.create(spec.name, {}, nil, {
    zh = spec.name, frequency = Frequency.Compulsory,
  })
  for k, v in pairs(fields) do s[k] = v end
  s.__spec = spec
  return s
end

function sgs.CreateDistanceSkill(spec)
  return markerSpec(spec, { distance_correct = spec.correct_func })
end

function sgs.CreateMaxCardsSkill(spec)
  return markerSpec(spec, { max_cards_extra = spec.extra_func, max_cards_fixed = spec.fixed_func })
end

function sgs.CreateTargetModSkill(spec)
  return markerSpec(spec, {
    target_residue = spec.residue_func,
    target_distance_limit = spec.distance_limit_func,
    target_extra = spec.extra_target_func,
  })
end

function sgs.CreateAttackRangeSkill(spec)
  return markerSpec(spec, { attack_range_extra = spec.extra_func })
end

function sgs.CreateProhibitSkill(spec)
  return markerSpec(spec, { prohibit = spec.is_prohibited })
end

function sgs.CreateFilterSkill(spec)
  -- 原版这些回调是**方法**：脚本写成 function(self, card)。
  -- 调用时必须把技能自身作为第一个参数传进去（等价于原版的冒号调用）。
  local s
  local function suitOf(card)
    -- FilterSkill 的 view_as 返回一张改过的牌；effSuit 要的是「花色」
    local ok, made = pcall(spec.view_as, s, card)
    if not ok then return nil end
    if type(made) == "number" then return made end
    if type(made) == "table" and made.suit then return made.suit end
    return nil
  end
  s = markerSpec(spec, {
    filter_view = suitOf,
    filter_view_filter = function(card) return spec.view_filter(s, card) == true end,
  })
  return s
end

-- ===== 卡牌构造（卡牌包扩展用）=====
-- 原版 sgs.CreateTrickCard / CreateBasicCard / CreateEquipCard / CreateWeapon /
-- CreateArmor / CreateTreasure 用于定义**新卡种**（卡牌包扩展包）。
-- 本引擎用 Cards.define 登记卡种定义，效果走 spec.on_effect / spec.on_use。

-- 子类（对应原版 LuaTrickCard::SubClass 等）
sgs.LuaTrickCard_TypeNormal = 0
sgs.LuaTrickCard_TypeDelayedTrick = 1
sgs.LuaTrickCard_TypeAOE = 2
sgs.LuaTrickCard_TypeGlobalEffect = 3
sgs.LuaTrickCard_TypeSingleTargetTrick = 4

-- 把 spec 的效果函数包成引擎 Cards.define 需要的 effect(room, use)
local function makeCardEffect(spec)
  return function(room, use)
    local from, to = use.from, use.to and use.to[1]
    if spec.on_use then
      spec.on_use(spec.__card, room, from, use.to or {})
      return
    end
    if spec.on_effect then
      for _, t in ipairs(use.to or {}) do
        spec.on_effect(spec.__card, { card = use.card, from = from, to = t })
      end
    end
  end
end

-- 统一登记：ctype 由调用方给，target 由 target_fixed / subclass 推导
local function defineLuaCard(spec, ctype, overrides)
  local name = spec.name or spec.class_name
  assert(type(name) == "string", "卡牌需要 name")

  local target = "enemy"
  if spec.target_fixed then
    target = "self"
  else
    local sc = spec.subclass or 0
    if sc == sgs.LuaTrickCard_TypeAOE then
      target = "all_other"
    elseif sc == sgs.LuaTrickCard_TypeGlobalEffect then
      target = "all"
    end
  end

  local def = {
    zh = sgs.Translations[name] or name,
    ctype = ctype,
    target = target,
    nullifiable = (ctype == Card.Type.Trick) and (spec.nullifiable ~= false),
    effect = makeCardEffect(spec),
  }
  if (spec.subclass or 0) == sgs.LuaTrickCard_TypeDelayedTrick then
    def.delayed = true
  end
  for k, v in pairs(overrides or {}) do def[k] = v end

  Cards.define(name, def)

  -- 返回一张可用的实例（与原版一致：构造函数返回一张卡）
  local c = Card.create(-1, name, spec.suit or Card.Suit.NoSuit, spec.number or 0, ctype)
  spec.__card = c
  spec.__def = def
  return c
end

function sgs.CreateTrickCard(spec)
  return defineLuaCard(spec, Card.Type.Trick)
end

function sgs.CreateBasicCard(spec)
  return defineLuaCard(spec, Card.Type.Basic)
end

function sgs.CreateEquipCard(spec)
  return defineLuaCard(spec, Card.Type.Equip, {
    equip = spec.equip_slot or "weapon",
  })
end

function sgs.CreateWeapon(spec)
  return defineLuaCard(spec, Card.Type.Equip, {
    equip = "weapon",
    range = spec.range or 1,
  })
end

function sgs.CreateArmor(spec)
  return defineLuaCard(spec, Card.Type.Equip, { equip = "armor" })
end

-- 宝物：本引擎只有 武器/防具/进攻马/防御马 四个槽位，没有宝物槽。
-- 这里登记为防具槽以便能装备，但语义上并不等价（已在下方注明）。
function sgs.CreateTreasure(spec)
  return defineLuaCard(spec, Card.Type.Equip, { equip = "armor" })
end

-- ===== 技能牌 =====
-- 原版的大量技能都实现为「技能牌」：把效果写在一张没有实体的抽象牌上，
-- 发动技能即视为使用这张牌（见 extension-doc/4-SkillCard.lua）。
-- 这里产出的是一张 virtual Card，附带 skill_card 规格；引擎在
-- Room:_useSkillCard 里拦下它，改走 on_use / on_effect。

-- 回调包装：进入前置位 sgs.Self / sgs.CurrentRoom（引擎会把它们写在
-- card.__user / card.__room 上），离开后还原。
local function wrapSkillCardFn(fn)
  if type(fn) ~= "function" then return nil end
  return function(self, ...)
    local prev, prev_room = sgs.Self, sgs.CurrentRoom
    sgs.Self = self.__user
    sgs.CurrentRoom = self.__room
    local ok, res = pcall(fn, self, ...)
    sgs.Self, sgs.CurrentRoom = prev, prev_room
    if not ok then error(res, 0) end
    return res
  end
end

function sgs.CreateSkillCard(spec)
  local name = spec.name or "skill_card"
  local c = Cards.get(name)
  local card = Card.create(-1, name, Card.Suit.NoSuit, 0, (c and c.ctype) or Card.Type.Basic)
  card.virtual = true
  card.phantom = false    -- 有实体来源（subcards），只是没有卡牌定义
  card.subcards = {}
  card.skill_card = spec
  card.target_fixed = spec.target_fixed == true
  card.will_throw = spec.will_throw ~= false -- 默认 true
  card.can_recast = spec.can_recast == true
  card.__user, card.__room = nil, nil
  -- 包装一次即可（在 spec 上就地替换，不能重复包装）
  for _, k in ipairs({ "on_use", "on_effect", "filter", "feasible" }) do
    local w = wrapSkillCardFn(spec[k])
    if w then spec[k] = w end
  end
  return card
end

-- sgs.Card_Parse("name:skill[suit:number]=id+id") 或 "@Class=ids" / "#obj:ids"
-- 主要由原版 bot 脚本用来构造虚拟牌；本引擎的 BOT 不依赖它，这里做最小可用实现。
local SUIT_BY_NAME = {
  spade = Card.Suit.Spade, heart = Card.Suit.Heart,
  club = Card.Suit.Club, diamond = Card.Suit.Diamond,
  no_suit = Card.Suit.NoSuit,
}
local function parseNumber(s)
  if s == "A" then return 1 end
  if s == "J" then return 11 end
  if s == "Q" then return 12 end
  if s == "K" then return 13 end
  return tonumber(s) or 0
end

function sgs.Card_Parse(str)
  if type(str) ~= "string" then return nil end
  -- "@Class=ids"：技能卡，名字取 Class 的 snake_case
  local cls, ids = string.match(str, "^@([%w_]+)=(.*)$")
  if not cls then
    -- "#obj:ids"：Lua 技能卡
    cls, ids = string.match(str, "^#([%w_]+):(.*)$")
  end
  if cls then
    local c = Card.create(-1, sgs.lowerCardName(cls), Card.Suit.NoSuit, 0, Card.Type.Basic)
    c.virtual = true
    c.subcards = {}
    for id in string.gmatch(ids or "", "%d+") do
      table.insert(c.subcards, { id = tonumber(id) })
    end
    return c
  end
  -- "name:skill[suit:number]=ids"
  local name, skill, suit, number, rest =
    string.match(str, "^([%w_]+):([%w_]+)%[([%w_]+):([%w]+)%]=(.*)$")
  if not name then
    name = string.match(str, "^([%w_]+)$")
    if not name then return nil end
    skill, suit, number, rest = "", "no_suit", "0", "."
  end
  local c = Card.create(-1, sgs.lowerCardName(name),
    SUIT_BY_NAME[string.lower(suit or "no_suit")] or Card.Suit.NoSuit,
    parseNumber(number or "0"), Card.Type.Basic)
  c.virtual = true
  c.skill_name = skill
  c.subcards = {}
  for id in string.gmatch(rest or "", "%d+") do
    table.insert(c.subcards, { id = tonumber(id) })
  end
  return c
end

-- 原版常用构造体

-- sgs.CardUseStruct(card, from, to)：to 可为玩家或玩家列表
function sgs.CardUseStruct(card, from, to)
  local list = {}
  if type(to) == "table" and to[1] then
    for _, t in ipairs(to) do table.insert(list, t) end
  elseif to then
    table.insert(list, to)
  end
  return { card = card, from = from, to = list }
end

-- sgs.DamageStruct(from, to, damage, nature)
function sgs.DamageStruct(from, to, damage, nature)
  return { from = from, to = to, n = damage or 1, damage = damage or 1,
    nature = nature or "normal" }
end

-- sgs.LogMessage()：原版日志对象，本引擎只记录 type/card_str 等字段
function sgs.LogMessage()
  return { type = "", from = nil, to = {}, arg = "", arg2 = "", card_str = "" }
end

-- sgs.qlist(容器)：原版遍历 QList；本引擎的列表就是 Lua 表，原样返回
function sgs.qlist(t) return t or {} end

-- sgs.CardMoveReason(...) 与 sgs.LogMessage 类似，只作数据载体
function sgs.CardMoveReason(_reason, _name, _skill, _event, _extra)
  return { m_reason = _reason, m_playerId = _name, m_skillName = _skill,
    m_eventName = _event, m_targetId = _extra }
end

-- ===== Sanguosha 单例 =====

local Sanguosha = {}

-- sgs.QVariant 传进来的可能是数值或字符串，取数字用这个
function sgs.toNumber(v)
  if type(v) == "number" then return v end
  local n = tonumber(v)
  if n then return n end
  -- 兜底：非数字就保持原值，交由调用方判断
  return v
end

-- CamelCase -> snake_case："Duel" -> "duel"，"ArcheryAttack" -> "archery_attack"
function sgs.lowerCardName(n)
  n = tostring(n or "")
  local s = string.gsub(n, "(%u)", function(c) return "_" .. string.lower(c) end)
  s = string.gsub(s, "^_", "")
  return string.lower(s)
end

-- 原版脚本常写 sgs.Sanguosha:cloneCard("Duel", ...)（首字母大写），
-- 而本引擎用 snake_case，这里统一归一。
local CARD_NAME_ALIAS = {
  duel = "duel", jink = "dodge", slash = "slash", peach = "peach",
  analeptic = "analeptic", snatch = "snatch", dismantlement = "dismantlement",
  indulgence = "indulgence", supplyshortage = "supply_shortage",
  lightning = "lightning", archeryattack = "archery_attack",
  savageassault = "savage_assault", exnihilo = "ex_nihilo",
  ironchain = "iron_chain", fireattack = "fire_attack",
  godsalvation = "god_salvation", amazinggrace = "amazing_grace",
  collateral = "collateral", fireslash = "fire_slash",
  thunderslash = "thunder_slash", nullification = "nullification",
}

function Sanguosha:cloneCard(name, suit, number)
  local lower = sgs.lowerCardName(name)
  name = CARD_NAME_ALIAS[lower] or CARD_NAME_ALIAS[string.lower(name or "")]
    or CARD_ALIAS[name] or lower
  local def = Cards.get(name)
  local real_suit = suit or Card.Suit.NoSuit
  if real_suit == sgs.Card_SuitToBeDecided then real_suit = Card.Suit.NoSuit end
  local c = Card.create(-1, name, real_suit, number or 0, def and def.ctype or Card.Type.Basic)
  -- cloneCard 在本引擎里只用于转化技产出的虚拟牌；标记 virtual 后
  -- Room:useCard 才会去取 subcards 对应的实体牌
  c.virtual = true
  c.subcards = {}
  return c
end

function Sanguosha:matchExpPattern(pattern, _player, card)
  return ExpPattern.match(pattern, card, "hand")
end

function Sanguosha:getCard(_id) return nil end
function Sanguosha:currentRoomState() return { getCurrentCardUsePattern = function() return "" end } end

sgs.Sanguosha = Sanguosha

-- sgs.Self：原版脚本在 view_filter / enabled_at_play 里读它取「当前操作者」。
-- 由 wrapCallbacks 在进入回调前置位，离开后还原。
sgs.Self = nil

return sgs
