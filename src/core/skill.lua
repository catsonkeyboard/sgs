-- 技能基类 + 触发事件系统
--
-- 事件命名对齐原版 QSanguosha 的 TriggerEvent（src/core/structs.h），
-- 这样后续迁移 diy/ 社区扩展与武将技能时可以直接对号入座。
--
-- 触发语义（对应原版 RoomThread::trigger）：
--   - 同一事件上可挂多个技能，按 priority 升序依次执行
--   - 任一技能返回 true 即截断管线（对应原版「取消结算」，如【无懈可击】）
--   - GameRule 本身也是一个 TriggerSkill，priority 最低以保证规则先跑
local class = require "src.class"

local TriggerEvent = {
  -- 局面
  GameStart = "GameStart",
  TurnStart = "TurnStart",
  TurnEnd = "TurnEnd",
  EventPhaseStart = "EventPhaseStart",
  EventPhaseProceeding = "EventPhaseProceeding",
  EventPhaseEnd = "EventPhaseEnd",
  EventPhaseChanging = "EventPhaseChanging",
  EventPhaseSkipping = "EventPhaseSkipping",

  -- 摸牌
  DrawNCards = "DrawNCards",
  AfterDrawNCards = "AfterDrawNCards",

  -- 体力
  PreHpRecover = "PreHpRecover",
  HpRecover = "HpRecover",
  PreHpLost = "PreHpLost",
  HpChanged = "HpChanged",
  MaxHpChanged = "MaxHpChanged",
  PostHpReduced = "PostHpReduced",

  -- 技能增删
  EventLoseSkill = "EventLoseSkill",
  EventAcquireSkill = "EventAcquireSkill",

  -- 判定
  StartJudge = "StartJudge",
  AskForRetrial = "AskForRetrial",
  FinishRetrial = "FinishRetrial",
  FinishJudge = "FinishJudge",

  -- 拼点
  PindianVerifying = "PindianVerifying",
  Pindian = "Pindian",

  -- 状态
  TurnedOver = "TurnedOver",
  ChainStateChanged = "ChainStateChanged",

  -- 伤害管线：武将技能最主要的挂载点
  ConfirmDamage = "ConfirmDamage",
  Predamage = "Predamage",
  DamageForseen = "DamageForseen",
  DamageCaused = "DamageCaused",
  DamageInflicted = "DamageInflicted",
  PreDamageDone = "PreDamageDone",
  DamageDone = "DamageDone",
  Damage = "Damage",
  Damaged = "Damaged",
  DamageComplete = "DamageComplete",

  -- 濒死与死亡
  Dying = "Dying",
  QuitDying = "QuitDying",
  AskForPeaches = "AskForPeaches",
  AskForPeachesDone = "AskForPeachesDone",
  Death = "Death",
  BuryVictim = "BuryVictim",
  BeforeGameOverJudge = "BeforeGameOverJudge",
  GameOverJudge = "GameOverJudge",
  GameFinished = "GameFinished",

  -- 杀的结算
  SlashEffected = "SlashEffected",
  SlashProceed = "SlashProceed",
  SlashHit = "SlashHit",
  SlashMissed = "SlashMissed",
  JinkEffect = "JinkEffect",

  -- 卡牌管线
  CardAsked = "CardAsked",
  CardResponded = "CardResponded",
  BeforeCardsMove = "BeforeCardsMove",
  CardsMoveOneTime = "CardsMoveOneTime",
  PreCardUsed = "PreCardUsed",
  CardUsed = "CardUsed",
  TargetChoosing = "TargetChoosing",
  TargetConfirming = "TargetConfirming",
  TargetChosen = "TargetChosen",
  TargetConfirmed = "TargetConfirmed",
  CardEffect = "CardEffect",
  CardEffected = "CardEffected",
  PostCardEffected = "PostCardEffected",
  CardFinished = "CardFinished",
  TrickCardCanceling = "TrickCardCanceling",

  ChoiceMade = "ChoiceMade",

  -- 国战专用（原版 Hegemony 分支）
  GeneralShown = "GeneralShown",
  GeneralHidden = "GeneralHidden",
  GeneralRemoved = "GeneralRemoved",
}

-- 技能触发频率
local Frequency = {
  NotFrequent = "NotFrequent", -- 主动技
  Frequent = "Frequent",       -- 频繁技（原版：每次都可选择发动）
  Compulsory = "Compulsory",   -- 锁定技
  Limited = "Limited",         -- 限定技
  Wake = "Wake",               -- 觉醒技
  Lord = "Lord",               -- 主公技：只有担任主公时才能发动
}

local Skill = class("Skill")

function Skill:init(name, opts)
  opts = opts or {}
  self.name = name
  self.zh = opts.zh or name
  self.priority = opts.priority or 0
  self.frequency = opts.frequency or Frequency.NotFrequent
end

-- 是否监听某事件；true 表示应被纳入触发管线
function Skill:listens(_event)
  return false
end

-- 返回 true 表示截断管线（取消后续技能与默认结算）
function Skill:onTrigger(_event, _room, _player, _data)
  return false
end

local TriggerSkill = class("TriggerSkill", Skill)

-- events: 字符串或字符串数组
-- on_trigger: function(skill, room, player, data) -> bool（true 截断）
function TriggerSkill:init(name, events, on_trigger, opts)
  Skill.init(self, name, opts)
  self.events = {}
  if type(events) == "string" then events = { events } end
  for _, e in ipairs(events or {}) do self.events[e] = true end
  self.on_trigger = on_trigger
  self.can_trigger = opts and opts.can_trigger
end

function TriggerSkill:listens(event)
  return self.events[event] == true
end

function TriggerSkill:onTrigger(event, room, player, data)
  if self.can_trigger and not self:can_trigger(room, player, data) then
    return false
  end
  if self.on_trigger then
    return self.on_trigger(self, room, player, data) == true
  end
  return false
end

-- 转化技：把手牌当作另一张牌来使用/打出。
-- 三国杀技能机制的核心（原版 ViewAsSkill，swig/luaskills.i 有 1789 行支撑）。
-- view_as(cards) 由若干手牌合成一张虚拟 Card，返回 nil 表示当前选择不成立。
local ViewAsSkill = class("ViewAsSkill", Skill)

function ViewAsSkill:init(name, opts)
  Skill.init(self, name, opts)
  self.result_name = opts and opts.result_name -- 转化后的牌名，如 "slash"
  self.n = (opts and opts.n) or 1              -- 需消耗手牌数，可为 {min, max}
  self.view_filter = opts and opts.view_filter -- 可选：哪些手牌可被选中
  -- 牌面写「一张XX**手牌**」的技能（倾国/双雄/丈八蛇矛/乱击）只认手牌；
  -- 默认（写「一张XX牌」，如武圣红色牌、国色方块牌、奇袭黑色牌、急救红色牌）
  -- 装备区的牌也可以被转化——装备区的牌同样是「自己的牌」（官方 FAQ 口径）
  self.hand_only = (opts and opts.hand_only) == true
  self.enabled_at_play = (opts and opts.enabled_at_play) ~= false
  self.enabled_at_response = (opts and opts.enabled_at_response) or nil
end

-- cards: 选中的手牌列表 -> 虚拟 Card 或 nil
function ViewAsSkill:view_as(_cards)
  return nil
end

function ViewAsSkill:listens(_event)
  return false
end

return {
  TriggerEvent = TriggerEvent,
  Frequency = Frequency,
  Skill = Skill,
  TriggerSkill = TriggerSkill,
  ViewAsSkill = ViewAsSkill,
}
