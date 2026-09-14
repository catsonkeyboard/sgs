-- ExpPattern：原版 QSanguosha 的卡牌匹配表达式
-- 形如 "class|suit|number|place"，任一段可省略（省略即通配），
-- 段内可用逗号分隔多个取值；结尾的 "!" 表示排除【鸡肋】牌（本引擎无鸡肋，忽略）。
--
-- 例：
--   ".|club|.|hand"          梅花手牌
--   ".|black"                黑色牌
--   "EquipCard|.|.|hand"     手牌中的装备牌
--   "slash"                 【杀】
--   "BasicCard,EquipCard|black"  黑色基本牌或装备牌
local Card = require "src.core.card"
local Cards = require "src.core.cards"

local ExpPattern = {}

-- 原版类名 -> 本引擎的牌名或类型
-- 键一律小写：匹配前会把模式里的类名统一转小写，否则 EquipCard 查不到
local CLASS_ALIAS = {
  basiccard = "basic", trickcard = "trick", equipcard = "equip",
  slash = "slash", jink = "dodge", peach = "peach", analeptic = "analeptic",
  fireslash = "fire_slash", thunderslash = "thunder_slash",
  weapon = "weapon", armor = "armor", horse = "horse",
  offensivehorse = "offensive_horse", defensivehorse = "defensive_horse",
  nullification = "nullification", snatch = "snatch",
  dismantlement = "dismantlement", duel = "duel",
  indulgence = "indulgence", supplyshortage = "supply_shortage",
  lightning = "lightning", archeryattack = "archery_attack",
  savageassault = "savage_assault", exnihilo = "ex_nihilo",
  ironchain = "iron_chain", fireattack = "fire_attack",
  godsalvation = "god_salvation", amazinggrace = "amazing_grace",
  collateral = "collateral",
}

local SUIT_OF = {
  spade = Card.Suit.Spade, heart = Card.Suit.Heart,
  club = Card.Suit.Club, diamond = Card.Suit.Diamond,
}

local function split(s, sep)
  local out = {}
  for part in string.gmatch(s, "([^" .. sep .. "]+)") do
    table.insert(out, part)
  end
  return out
end

local function anyMatch(list, ok)
  for _, v in ipairs(list) do
    if ok(v) then return true end
  end
  return false
end

-- 匹配类名段：可直接给牌名（snake_case），也接受原版类名
local function matchClass(card, field)
  if field == "." then return true end -- 通配
  local names = split(field, ",")
  return anyMatch(names, function(n)
    n = string.lower(n)
    local mapped = CLASS_ALIAS[n] or n
    if mapped == "basic" then return card.ctype == Card.Type.Basic end
    if mapped == "trick" then return card.ctype == Card.Type.Trick end
    if mapped == "equip" then return card.ctype == Card.Type.Equip end
    if mapped == "weapon" or mapped == "armor"
      or mapped == "offensive_horse" or mapped == "defensive_horse" then
      local def = Cards.get(card.name)
      return def and def.equip == mapped
    end
    if mapped == "horse" then
      local def = Cards.get(card.name)
      return def and (def.equip == "offensive_horse" or def.equip == "defensive_horse")
    end
    -- 原版 isKindOf 语义：Slash 含火杀/雷杀
    if mapped == "slash" then
      return card.name == "slash" or card.name == "fire_slash" or card.name == "thunder_slash"
    end
    return card.name == mapped
  end)
end

local function matchSuit(card, field)
  if field == "." then return true end
  local suits = split(field, ",")
  return anyMatch(suits, function(s)
    s = string.lower(s)
    if s == "black" then return not card:isRed() end
    if s == "red" then return card:isRed() end
    return card.suit == SUIT_OF[s]
  end)
end

local function matchNumber(card, field)
  if field == "." then return true end
  local nums = split(field, ",")
  return anyMatch(nums, function(p)
    local a, b = string.match(p, "^(%d+)~(%d+)$")
    if a then
      return card.number >= tonumber(a) and card.number <= tonumber(b)
    end
    return card.number == tonumber(p)
  end)
end

-- 区域段：本引擎目前只在「手牌」范围内做转化技筛选
local function matchPlace(card, field, place)
  if field == "." then return true end
  local places = split(field, ",")
  return anyMatch(places, function(p)
    p = string.lower(p)
    -- 未知的区域名一律**不匹配**：以前这里返回 true，
    -- 会让写错的区域段被静默忽略（本以为是"粗粒度"，其实是放行）
    if p == "hand" or p == "h" then return place == nil or place == "hand" end
    if p == "equip" or p == "e" then return place == "equip" end
    if p == "judge" or p == "j" then return place == "judge" end
    if p == "table" or p == "t" then return place == "table" end
    if p == "special" then return place == "special" end
    return false
  end)
end

-- pattern: 字符串；card: Card；place: "hand"/"equip"/"judge"（可选）
-- 说明：本引擎的转化技只在**手牌**范围内筛选（原版还有装备区/判定区），
-- 因此调用方传入的 place 目前恒为 "hand"；区域段仍会正常校验。
function ExpPattern.match(pattern, card, place)
  if not pattern or pattern == "" or pattern == "." then return true end
  -- 结尾的 "!" 表示排除【鸡肋】牌，交给 Player:isJilei 判断（见 room.lua）
  pattern = string.gsub(pattern, "!$", "")
  local parts = split(pattern, "|")
  if not matchClass(card, parts[1] or ".") then return false end
  if parts[2] and not matchSuit(card, parts[2]) then return false end
  if parts[3] and not matchNumber(card, parts[3]) then return false end
  if parts[4] and not matchPlace(card, parts[4], place) then return false end
  return true
end

return ExpPattern
