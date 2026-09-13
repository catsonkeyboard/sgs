-- 技能基类 + 触发事件系统
-- 事件命名对齐原版 TriggerEvent（GameStart/TurnStart/Damage/Dying/Death...），
-- 阶段 A1 起武将技能在此框架上长出。
local class = require "src.class"

local TriggerEvent = {
  GameStart = "GameStart",
  TurnStart = "TurnStart",
  TurnEnd = "TurnEnd",
  CardUsed = "CardUsed",
  DamageCaused = "DamageCaused",
  Damaged = "Damaged",
  Dying = "Dying",
  Death = "Death",
}

local Skill = class("Skill")

function Skill:init(name)
  self.name = name
end

local TriggerSkill = class("TriggerSkill", Skill)

function TriggerSkill:init(name, events, on_trigger)
  Skill.init(self, name)
  self.events = events        -- { Damage=true, Dying=true, ... }
  self.on_trigger = on_trigger -- function(event, room, data) → 规则效果
end

function TriggerSkill:onTrigger(event, room, data)
  if self.on_trigger then return self.on_trigger(event, room, data) end
end

return {
  TriggerEvent = TriggerEvent,
  Skill = Skill,
  TriggerSkill = TriggerSkill,
}
