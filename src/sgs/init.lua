-- sgs.* 兼容层（阶段 B 的地基，v0 先占位）
--
-- 目标：对外暴露与原版 swig 绑定一致的 API 形状，使 diy/ 社区扩展
-- （约 2 万行）能以最小改动加载。命名对照原版：
--   sgs.Sanguosha        → 引擎单例
--   sgs.Player           → 玩家类
--   sgs.Card             → 卡牌类
--   sgs.TriggerEvent     → 事件枚举
--   sgs.LuaTriggerSkill  → Lua 触发技能定义
-- （A1/B 阶段按 diy/ 扩展实际调用面逐项补齐）
local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Card = require "src.core.card"
local skill = require "src.core.skill"

local sgs = {}

sgs.Sanguosha = Engine.create()
sgs.Player = Player
sgs.Card = Card
sgs.TriggerEvent = skill.TriggerEvent

-- 原版扩展常见的技能注册入口形状
function sgs.LoadTranslationTable() end -- B 阶段实现
function sgs.AddSkill() end            -- B 阶段实现

return sgs
