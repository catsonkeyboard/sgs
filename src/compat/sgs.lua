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
  s.dynamic = true -- 结果牌名不固定，AI 需要试算

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
  return markerSpec(spec, { filter_view = spec.view_as, filter_view_filter = spec.view_filter })
end

-- ===== Sanguosha 单例 =====

local Sanguosha = {}

function Sanguosha:cloneCard(name, suit, number)
  name = CARD_ALIAS[name] or name
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
