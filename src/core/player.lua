-- 玩家：体力/手牌/装备区/判定区/身份/回合标记
-- 对应原版 Player + ServerPlayer 的核心子集（src/core/player.h, src/server/serverplayer.h）
--
-- 区域对齐原版 Player::Place：PlaceHand(self.hand) / PlaceEquip(self.equips) /
-- PlaceDelayedTrick(self.judges) / DiscardPile / DrawPile 等。
local class = require "src.class"

local Player = class("Player")

-- 身份：对齐原版 Player::Role
Player.Role = { Lord = "lord", Loyalist = "loyalist", Rebel = "rebel", Renegade = "renegade" }
Player.ROLE_ZH = {
  lord = "主公", loyalist = "忠臣", rebel = "反贼", renegade = "内奸",
}

-- 装备槽位（对应 Cards def 的 equip 字段）
Player.EQUIP_SLOTS = { "weapon", "armor", "offensive_horse", "defensive_horse" }

function Player:init(name, general, seat, is_human)
  self.name = name
  self.general = general            -- engine 注册的武将表 {name, max_hp, kingdom, skills}
  self.seat = seat
  self.is_human = is_human or false
  self.max_hp = (general and general.max_hp) or 4
  self.hp = self.max_hp
  self.kingdom = (general and general.kingdom) or "qun"
  self.female = (general and general.female) or false -- 【结姻】等按性别选目标

  self.hand = {}                    -- 手牌
  self.equips = {                   -- 装备区
    weapon = nil, armor = nil,
    offensive_horse = nil, defensive_horse = nil,
  }
  self.judges = {}                  -- 判定区（延时锦囊）
  self.chained = false              -- 铁索连环状态
  self.turned_over = false          -- 翻面
  self.extra_skills = {}            -- 运行时获得的技能

  self.role = nil                   -- 身份
  self.alive = true
  self.phase = "not_active"
  self.slash_used = false           -- 本回合是否已使用杀
  self.slash_count = 0              -- 本回合使用杀的次数（诸葛连弩判定用）
  self.drunk = false                -- 本回合是否已饮酒
  self.skip_play = false            -- 乐不思蜀：跳过出牌阶段
  self.skip_draw = false            -- 兵粮寸断：跳过摸牌阶段
end

-- ===== 谁在操作这个座位 =====
--
-- 三态：human（UI 点击）/ bot（规则脚本）/ ai（LLM）。
-- 新增 controller 而不是复用 is_human，是因为二者语义不同：
--   is_human = 「这是不是人类座位」（决定 UI 要不要显示手牌、要不要响应点击）
--   controller = 「这一手由谁做决定」
-- AI 托管人类位时两个都要为真：既显示手牌，又由 AI 决策。
function Player:controlMode()
  if self.controller then return self.controller end
  return self.is_human and "human" or "bot"
end

-- 把座位交给某个响应源。is_human 不动——「谁看得到手牌」与「谁做决定」是两回事
function Player:setControl(mode)
  self.controller = mode
  return self
end

-- ===== 手牌 =====

function Player:cardCount()
  return #self.hand
end

function Player:findCardsByName(name)
  local found = {}
  for _, c in ipairs(self.hand) do
    if c.name == name then table.insert(found, c) end
  end
  return found
end

function Player:hasCard(name)
  for _, c in ipairs(self.hand) do
    if c.name == name then return true end
  end
  return false
end

-- 按对象身份从手牌移除并返回（找不到返回 nil）
function Player:takeCard(card)
  for i, c in ipairs(self.hand) do
    if c == card then return table.remove(self.hand, i) end
  end
  return nil
end

-- 从任意区域（手牌/装备区/判定区）按对象身份摘除一张牌。
-- 返回来源区域名（"hand"/"equip"/"judge"），便于调用方区分日志与触发
-- （如从装备区失去要触发【枭姬】，见 Room:_onEquipLost）。
-- 【过河拆桥】【顺手牵羊】按文档可作用于三个区域的任一张牌，
-- 之前 takeCard 只查手牌，拆装备/判定区会被静默忽略。
function Player:takeCardAnyZone(card)
  if self:takeCard(card) then return "hand" end
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    if self.equips[slot] == card then
      self.equips[slot] = nil
      return "equip"
    end
  end
  for i, c in ipairs(self.judges) do
    if c == card then
      table.remove(self.judges, i)
      return "judge"
    end
  end
  return nil
end

-- 所有可见区域的总牌数（卡牌守恒校验用）
-- 鸡肋：不能对该角色使用/打出某类牌。jilei 形如 { basic = true }。
-- 原版是「按类别封禁」，本引擎按 ctype 判断，也支持按牌名精确封禁
-- （jilei = { slash = true }）。
local JILEI_BY_CTYPE = { [0] = "basic", [1] = "trick", [2] = "equip" }

function Player:isJilei(card)
  if not (card and self.jilei) then return false end
  if self.jilei[card.name] then return true end
  local kind = JILEI_BY_CTYPE[card.ctype]
  return kind ~= nil and self.jilei[kind] == true
end

function Player:setJilei(kind, on)
  self.jilei = self.jilei or {}
  self.jilei[kind] = (on == nil) and true or (on and true or nil)
end

function Player:clearJilei() self.jilei = nil end

function Player:allCardCount()
  local n = #self.hand + #self.judges
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    if self.equips[slot] then n = n + 1 end
  end
  return n
end

-- ===== 装备 =====

function Player:hasEquip(name)
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    local c = self.equips[slot]
    if c and c.name == name then return c end
  end
  return nil
end

function Player:getWeapon()
  return self.equips.weapon
end

function Player:getArmor()
  return self.equips.armor
end

-- 装备一张牌；返回被替换下来的旧装备（可能为 nil）
function Player:equipCard(card, slot)
  local old = self.equips[slot]
  self.equips[slot] = card
  return old
end

-- 卸下并返回指定装备
function Player:unequipCard(card)
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    if self.equips[slot] == card then
      self.equips[slot] = nil
      return card
    end
  end
  return nil
end

-- ===== 攻击范围 / 距离修正 =====

-- 攻击范围：武器 range，无武器时为 1
function Player:attackRange()
  local w = self.equips.weapon
  if w then
    local Cards = require "src.core.cards"
    local def = Cards.get(w.name)
    if def and def.range and def.range > 0 then return def.range end
  end
  return 1
end

-- 进攻马 -1 / 防御马 +1；实际距离由 Room:distance 结合座位差计算
function Player:distanceModifier()
  return self.equips.offensive_horse and -1 or 0
end

function Player:defenseModifier()
  return self.equips.defensive_horse and 1 or 0
end

-- ===== 判定区 =====

function Player:addJudge(card)
  table.insert(self.judges, card)
end

function Player:removeJudge(card)
  for i, c in ipairs(self.judges) do
    if c == card then return table.remove(self.judges, i) end
  end
  return nil
end

function Player:hasDelayed(name)
  for _, c in ipairs(self.judges) do
    if c.name == name then return c end
  end
  return nil
end

return Player
