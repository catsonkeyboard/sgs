-- 卡牌：花色/点数/类型（对齐原版 Card 语义的子集）
local class = require "src.class"

local Card = class("Card")

Card.Suit = { NoSuit = 0, Spade = 1, Heart = 2, Club = 3, Diamond = 4 }
Card.Type = { Basic = 0, Trick = 1, Equip = 2 }

-- 中文名映射（UI 显示用；引擎逻辑用英文键）
Card.ZH = { slash = "杀", dodge = "闪", peach = "桃" }
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
  return string.format("%s%s-%d[%s]", self:suitString(), self.number, self:zhName(), self.id)
end

function Card:clone()
  return Card.create(self.id, self.name, self.suit, self.number, self.ctype)
end

return Card
