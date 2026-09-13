-- 引擎注册表：武将/技能/全局规则技能（对应原版 Engine 的注册职能）
local class = require "src.class"

local Engine = class("Engine")

function Engine:init()
  self.generals = {}        -- name -> {name, max_hp, skills}
  self.skills = {}          -- name -> Skill/TriggerSkill
  self.global_skills = {}   -- 全局规则类触发技能（游戏规则、技能效果等）
end

function Engine:registerGeneral(g)
  assert(g and g.name and g.max_hp, "general 需要 name/max_hp")
  self.generals[g.name] = g
end

function Engine:getGeneral(name)
  return self.generals[name]
end

function Engine:registerSkill(skill)
  self.skills[skill.name] = skill
end

function Engine:registerGlobalSkill(skill)
  table.insert(self.global_skills, skill)
end

return Engine
