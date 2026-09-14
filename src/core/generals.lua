-- 武将技能库
--
-- 技能定义对齐原版 src/package/standard-{shu,wei,wu,qun}-generals.cpp，
-- 事件名与 priority 语义沿用 core/skill.lua。
--
-- 技能分三类：
--   1) 触发技 TriggerSkill  —— 挂事件，可返回 true 截断结算
--   2) 转化技 ViewAsSkill   —— 把手牌当作另一张牌使用/打出（filter + result_name）
--   3) 标记技               —— 只挂标记，由引擎在特定判定处查询（如马术的距离修正）
--
-- 标记字段（引擎读取）：
--   unlimited_slash  出杀无次数限制       distance_mod  距离修正
--   no_trick_range   锦囊无视距离限制     auto_armor    无防具时视为装备该防具
--   no_target_empty  空手牌时不可被指定   savage_immune 免疫【南蛮入侵】
local Card = require "src.core.card"
local Cards = require "src.core.cards"
local sk = require "src.core.skill"
local TriggerSkill = sk.TriggerSkill
local ViewAsSkill = sk.ViewAsSkill
local TriggerEvent = sk.TriggerEvent
local Freq = sk.Frequency

local Generals = {}

-- 构造单牌转化技：一张符合 filter 的手牌 → result_name
local function singleViewAs(name, result_name, filter)
  local s = ViewAsSkill.create(name, { zh = name, result_name = result_name, n = 1 })
  s.filter = filter
  function s:view_as(cards)
    if #cards ~= 1 then return nil end
    local src = cards[1]
    if self.filter and not self.filter(src) then return nil end
    local def = Cards.get(self.result_name)
    local c = Card.create(-1, self.result_name, src.suit, src.number,
      def and def.ctype or Card.Type.Basic)
    c.virtual = true
    c.subcards = { src }
    return c
  end
  return s
end

-- 构造只挂标记的被动技
local function markerSkill(name, fields, freq)
  local s = TriggerSkill.create(name, {}, nil, { zh = name, frequency = freq or Freq.Compulsory })
  for k, v in pairs(fields) do s[k] = v end
  return s
end

local isRed = function(c) return c:isRed() end
local isBlack = function(c) return not c:isRed() end
local isSpade = function(c) return c.suit == Card.Suit.Spade end
local isClub = function(c) return c.suit == Card.Suit.Club end

-- ==================== 蜀 ====================

Generals.SHU = {
  {
    name = "刘备", key = "liubei", max_hp = 4, kingdom = "shu",
    skills = {
      -- 仁德：出牌阶段可将一张手牌交给其他角色，累计给出 3 张后回复 1 点体力
      singleViewAs("仁德", "rende", function() return true end),
      TriggerSkill.create("仁德·回血", TriggerEvent.CardUsed,
        function(_s, room, player, data)
          if not data or data.from ~= player then return false end
          local card = data.card
          if not card or card.name ~= "rende" then return false end
          player.rende_count = (player.rende_count or 0) + 1
          if player.rende_count >= 3 then
            player.rende_count = 0
            room:log("%s 发动【仁德】累计给出 3 张牌，回复 1 点体力", player.name)
            room:heal(player, 1)
          end
          return false
        end, { zh = "仁德" }),
    },
  },
  {
    name = "关羽", key = "guanyu", max_hp = 5, kingdom = "shu",
    skills = { singleViewAs("武圣", "slash", isRed) },
  },
  {
    name = "张飞", key = "zhangfei", max_hp = 4, kingdom = "shu",
    skills = { markerSkill("咆哮", { unlimited_slash = true }) },
  },
  {
    name = "诸葛亮", key = "zhugeliang", max_hp = 3, kingdom = "shu",
    skills = {
      -- 空城（锁定技）：没有手牌时不可成为【杀】或【决斗】的目标
      markerSkill("空城", { no_target_empty = true }),
    },
  },
  {
    name = "赵云", key = "zhaoyun", max_hp = 4, kingdom = "shu",
    skills = {
      singleViewAs("龙胆·杀", "slash", function(c) return c.name == "dodge" end),
      singleViewAs("龙胆·闪", "dodge", function(c)
        return c.name == "slash" or c.name == "fire_slash" or c.name == "thunder_slash"
      end),
    },
  },
  {
    name = "马超", key = "machao", max_hp = 4, kingdom = "shu",
    skills = {
      markerSkill("马术", { distance_mod = -1 }),
      -- 铁骑：使用【杀】指定目标后判定，红色则该【杀】不可被【闪】响应
      TriggerSkill.create("铁骑", TriggerEvent.TargetChosen,
        function(_s, room, player, data)
          if not data or data.from ~= player or not data.card then return false end
          if data.card.name ~= "slash" and data.card.name ~= "fire_slash"
            and data.card.name ~= "thunder_slash" then return false end
          if #room.drawPile == 0 then return false end
          local j = table.remove(room.drawPile)
          table.insert(room.discardPile, j)
          if j:isRed() then
            room:log("%s 发动【铁骑】，判定 %s 红色，此【杀】不可被闪避",
              player.name, j:suitString())
            data.card.cannot_dodge = true
          else
            room:log("%s 发动【铁骑】，判定 %s 黑色，无效果", player.name, j:suitString())
          end
          return false
        end, { zh = "铁骑" }),
    },
  },
  {
    name = "黄月英", key = "huangyueying", max_hp = 3, kingdom = "shu",
    skills = {
      markerSkill("奇才", { no_trick_range = true }),
      -- 集智：使用非延时锦囊牌后摸一张
      TriggerSkill.create("集智", TriggerEvent.CardUsed,
        function(_s, room, player, data)
          if not data or data.from ~= player or not data.card then return false end
          local def = Cards.get(data.card.name)
          if not def or def.ctype ~= Card.Type.Trick then return false end
          if Cards.isDelayed(data.card.name) then return false end
          room:log("%s 发动【集智】，摸一张牌", player.name)
          room:drawCards(player, 1)
          return false
        end, { zh = "集智" }),
    },
  },
  {
    name = "黄忠", key = "huangzhong", max_hp = 4, kingdom = "shu",
    skills = {
      -- 烈弓：目标手牌数不小于你的体力值时，此【杀】不可被【闪】响应
      TriggerSkill.create("烈弓", TriggerEvent.TargetChosen,
        function(_s, room, player, data)
          if not data or data.from ~= player or not data.to then return false end
          if not data.card then return false end
          if data.card.name ~= "slash" and data.card.name ~= "fire_slash"
            and data.card.name ~= "thunder_slash" then return false end
          if #data.to.hand >= player.hp then
            room:log("%s 发动【烈弓】，此【杀】不可被闪避", player.name)
            data.card.cannot_dodge = true
          end
          return false
        end, { zh = "烈弓" }),
    },
  },
  {
    name = "魏延", key = "weiyan", max_hp = 4, kingdom = "shu",
    skills = {
      -- 狂骨：对距离 1 以内的角色造成 1 点伤害后，回复 1 点体力
      TriggerSkill.create("狂骨", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.from ~= player or not data.to then return false end
          if room:distance(player, data.to) > 1 then return false end
          if player.hp >= player.max_hp then return false end
          room:log("%s 发动【狂骨】，回复 1 点体力", player.name)
          room:heal(player, 1)
          return false
        end, { zh = "狂骨" }),
    },
  },
  {
    name = "庞统", key = "pangtong", max_hp = 3, kingdom = "shu",
    skills = {
      singleViewAs("连环", "iron_chain", isClub),
      -- 涅槃（限定技）：濒死时丢弃所有牌，回复体力至上限
      TriggerSkill.create("涅槃", TriggerEvent.Dying,
        function(s, room, player, _data)
          if s.niepan_used then return false end
          s.niepan_used = true
          for i = #player.hand, 1, -1 do
            table.insert(room.discardPile, table.remove(player.hand, i))
          end
          for _, slot in ipairs({ "weapon", "armor", "offensive_horse", "defensive_horse" }) do
            if player.equips[slot] then
              table.insert(room.discardPile, player.equips[slot])
              player.equips[slot] = nil
            end
          end
          player.hp = player.max_hp
          room:log("%s 发动【涅槃】（限定技），弃置所有牌并回复至 %d 点体力",
            player.name, player.max_hp)
          return true -- 截断：不再走濒死求桃
        end, { zh = "涅槃", frequency = Freq.Limited }),
    },
  },
  {
    name = "卧龙", key = "wolong", max_hp = 3, kingdom = "shu",
    skills = {
      markerSkill("八阵", { auto_armor = "eight_diagram" }),
      singleViewAs("火计", "fire_attack", isRed),
      singleViewAs("看破", "nullification", isBlack),
    },
  },
  {
    name = "刘禅", key = "liushan", max_hp = 3, kingdom = "shu",
    skills = {
      -- 享乐（锁定技）：成为【杀】的目标时，若体力大于 1，使用者需弃一张牌，否则该【杀】无效
      markerSkill("享乐", { xiangle = true }),
    },
  },
  {
    name = "孟获", key = "menghuo", max_hp = 4, kingdom = "shu",
    skills = {
      markerSkill("祸首", { savage_immune = true }),
      -- 再起：摸牌阶段若已受伤，放弃摸牌改为回复 1 点体力
      TriggerSkill.create("再起", TriggerEvent.DrawNCards,
        function(_s, room, player, data)
          if player.hp >= player.max_hp then return false end
          data.n = 0
          room:log("%s 发动【再起】，放弃摸牌改为回复 1 点体力", player.name)
          room:heal(player, 1)
          return false
        end, { zh = "再起" }),
    },
  },
  {
    name = "祝融", key = "zhurong", max_hp = 4, kingdom = "shu",
    skills = {
      markerSkill("巨象", { savage_immune = true }),
      -- 烈刃：【杀】造成伤害后，可弃置一张手牌对其追加 1 点伤害
      TriggerSkill.create("烈刃", TriggerEvent.Damage,
        function(_s, room, player, data)
          if not data or data.from ~= player or not data.to then return false end
          if not data.to.alive or #player.hand == 0 then return false end
          local c = player.hand[1]
          player:takeCard(c)
          table.insert(room.discardPile, c)
          room:log("%s 发动【烈刃】，弃置一张牌对 %s 追加 1 点伤害",
            player.name, data.to.name)
          room:damage(player, data.to, 1)
          return false
        end, { zh = "烈刃" }),
    },
  },
  {
    name = "甘夫人", key = "ganfuren", max_hp = 3, kingdom = "shu",
    skills = {
      -- 淑慎：出牌阶段可弃置一张黑色手牌，令一名角色回复 1 点体力
      singleViewAs("淑慎", "shushen", isBlack),
      TriggerSkill.create("淑慎·治疗", TriggerEvent.CardUsed,
        function(_s, room, player, data)
          if not data or data.from ~= player or not data.card then return false end
          if data.card.name ~= "shushen" then return false end
          local t = (data.to and data.to[1]) or player
          room:log("%s 发动【淑慎】，%s 回复 1 点体力", player.name, t.name)
          room:heal(t, 1)
          return false
        end, { zh = "淑慎" }),
    },
  },
}

-- 汇总所有已实现的武将
function Generals.all()
  local out = {}
  for _, g in ipairs(Generals.SHU) do table.insert(out, g) end
  return out
end

-- 收集某玩家的技能标记值（同名标记取绝对值最大者）
function Generals.marker(player, key, default)
  local best = default
  local skills = (player.general and player.general.skills) or {}
  for _, s in ipairs(skills) do
    local v = s[key]
    if v ~= nil then
      if type(v) == "number" then
        if best == nil or math.abs(v) > math.abs(best) then best = v end
      else
        best = v
      end
    end
  end
  for _, s in ipairs(player.extra_skills or {}) do
    if s[key] ~= nil then best = s[key] end
  end
  return best
end

return Generals
