-- 玩家：体力/手牌/存活状态/回合标记（对应原版 Player + ServerPlayer 的核心子集）
local class = require "src.class"

local Player = class("Player")

function Player:init(name, general, seat, is_human)
  self.name = name
  self.general = general            -- engine 注册的武将表 {name, max_hp, skills}
  self.seat = seat
  self.is_human = is_human or false
  self.max_hp = general.max_hp
  self.hp = general.max_hp
  self.hand = {}                    -- Card 列表
  self.alive = true
  self.phase = "not_active"
  self.slash_used = false           -- 本回合是否已使用杀
end

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

return Player
