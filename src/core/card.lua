-- 卡牌：花色/点数/类型（对齐原版 Card 语义的子集）
local class = require "src.class"

local Card = class("Card")

Card.Suit = { NoSuit = 0, Spade = 1, Heart = 2, Club = 3, Diamond = 4 }
Card.Type = { Basic = 0, Trick = 1, Equip = 2 }

-- 中文名映射（UI 显示用；引擎逻辑用英文键）。锦囊/装备由 cards.lua 注册时补入。
Card.ZH = {
  slash = "杀", dodge = "闪", peach = "桃",
  analeptic = "酒", fire_slash = "火杀", thunder_slash = "雷杀",
}
Card.SUIT_STR = { [Card.Suit.Spade] = "S", [Card.Suit.Heart] = "H",
  [Card.Suit.Club] = "C", [Card.Suit.Diamond] = "D" }

function Card:init(id, name, suit, number, ctype)
  self.id = id
  self.name = name          -- "slash" / "dodge" / "peach"
  self.suit = suit or Card.Suit.NoSuit
  self.number = number or 0
  self.ctype = ctype or Card.Type.Basic
end

function Card:isRed()
  return self.suit == Card.Suit.Heart or self.suit == Card.Suit.Diamond
end

function Card:zhName()
  return Card.ZH[self.name] or self.name
end

function Card:suitString()
  return Card.SUIT_STR[self.suit] or "?"
end

function Card:displayName()
  return string.format("%s%s-%s[#%s]", self:suitString(), self.number, self:zhName(), self.id)
end

-- 复制一张牌。原版扩展常用 `LuaSkillCard:clone()` 得到一张新的技能牌，
-- 因此必须把技能相关的属性（skill_card / subcards / virtual 等）一起带过去，
-- 否则克隆出来的牌会被当成普通卡牌走卡牌结算。
function Card:clone()
  local c = Card.create(self.id, self.name, self.suit, self.number, self.ctype)
  c.virtual = self.virtual
  c.phantom = self.phantom
  c.skill_card = self.skill_card
  c.skill_name = self.skill_name
  c.can_recast = self.can_recast
  c.will_throw = self.will_throw
  c.target_fixed = self.target_fixed
  c.no_distance_limit = self.no_distance_limit
  c.subcards = {}
  for _, sc in ipairs(self.subcards or {}) do table.insert(c.subcards, sc) end
  return c
end

return Card
