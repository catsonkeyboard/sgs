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

local EQUIP_SLOTS = { "weapon", "armor", "offensive_horse", "defensive_horse" }
local PHASE_ZH = {
  start = "开始", judge = "判定", draw = "摸牌",
  play = "出牌", discard = "弃牌", finish = "结束",
}

-- 延时锦囊的命中条件（【鬼才】改判时需要独立于 def.judge 的纯函数，
-- 因为 def.judge 会打印判定日志，不能被预演调用）
local JUDGE_HIT = {
  indulgence = function(c) return c.suit ~= Card.Suit.Heart end,
  supply_shortage = function(c) return c.suit ~= Card.Suit.Club end,
  lightning = function(c) return c.suit == Card.Suit.Spade and c.number >= 2 and c.number <= 9 end,
  ganglie = function(c) return c.suit ~= Card.Suit.Heart end,
}

-- 自动选敌：身份局按阵营排序，非身份局就是「除自己外的存活者」
local function foes(p, room)
  local all = {}
  for _, q in ipairs(room.players) do
    if q ~= p and q.alive then table.insert(all, q) end
  end
  if not room.identity_mode or not p.role then return all end
  local enemies = {}
  for _, q in ipairs(all) do
    local hostile
    if p.role == "lord" or p.role == "loyalist" then
      hostile = (q.role == "rebel" or q.role == "renegade")
    elseif p.role == "rebel" then
      hostile = (q.role == "lord" or q.role == "loyalist")
    elseif p.role == "renegade" then
      hostile = (#room:alivePlayers() <= 2) or (q.role == "rebel")
    else
      hostile = true
    end
    if hostile then table.insert(enemies, q) end
  end
  return #enemies > 0 and enemies or all
end

-- 第一个在给定范围内的敌人；range 传 math.huge 表示无视距离
local function firstInRange(p, room, range)
  range = range or p:attackRange()
  for _, q in ipairs(foes(p, room)) do
    if room:distance(p, q) <= range then return q end
  end
  return nil
end

-- 凭空生成的虚拟牌（【神速】）：无实体来源，用完即消失
local function phantomCard(name)
  local def = Cards.get(name)
  local c = Card.create(-1, name, Card.Suit.NoSuit, 0, def and def.ctype or Card.Type.Basic)
  c.virtual = true
  c.phantom = true
  c.subcards = {}
  return c
end

-- 从牌堆顶摸一张用于判定（含洗回弃牌堆）
local function drawForJudge(room)
  if #room.drawPile == 0 and #room.discardPile > 0 then
    room:shuffle(room.discardPile)
    for _, c in ipairs(room.discardPile) do table.insert(room.drawPile, c) end
    room.discardPile = {}
  end
  return table.remove(room.drawPile)
end

local function isSlashName(n)
  return n == "slash" or n == "fire_slash" or n == "thunder_slash"
end

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
          if not isSlashName(data.card.name) then return false end
          -- data.to 是目标列表，取第一个目标
          local victim = data.to[1]
          if not victim then return false end
          if #victim.hand >= player.hp then
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
        function(s, room, player, data)
          -- Dying 以「濒死者」为主语广播，必须确认濒死的是自己
          if not data or data.player ~= player then return false end
          if s.niepan_used then return false end
          s.niepan_used = true
          for i = #player.hand, 1, -1 do
            table.insert(room.discardPile, table.remove(player.hand, i))
          end
          for _, slot in ipairs(EQUIP_SLOTS) do
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

-- ==================== 魏 ====================
-- 对齐原版 src/package/standard-wei-generals.cpp（WEI 001-016）

-- 裸衣 / 强袭等「每回合一次」的技能，用 TurnStart 重置标记
local function resetFlag(name, opts)
  return TriggerSkill.create(name, TriggerEvent.TurnStart,
    function(_s, _room, player, data)
      if data and data.player == player then player[opts.flag] = false end
      return false
    end, { zh = opts.zh or name })
end

Generals.WEI = {
  {
    name = "曹操", key = "caocao", max_hp = 4, kingdom = "wei",
    skills = {
      -- 奸雄：受到伤害后，获得造成伤害的那张牌
      TriggerSkill.create("奸雄", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.to ~= player or not data.card then return false end
          local card = data.card
          -- 转化技的虚拟牌没有实体，取其来源实体牌
          local real = (card.virtual and card.subcards and card.subcards[1]) or card
          room:log("%s 发动【奸雄】，获得【%s】", player.name, real:zhName())
          room:obtain(player, real)
          return false
        end, { zh = "奸雄" }),
    },
  },
  {
    name = "司马懿", key = "simayi", max_hp = 3, kingdom = "wei",
    skills = {
      -- 反馈：受到伤害后，获得来源的一张牌
      TriggerSkill.create("反馈", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.to ~= player or not data.from then return false end
          local src = data.from
          if src == player or not src.alive then return false end
          if #src.hand == 0 and not src.equips.weapon and not src.equips.armor
            and not src.equips.offensive_horse and not src.equips.defensive_horse then
            return false
          end
          room:log("%s 发动【反馈】，获得 %s 的一张牌", player.name, src.name)
          room:takeOneCard(player, src)
          return false
        end, { zh = "反馈" }),
      -- 鬼才：判定牌生效前，可用一张手牌替换判定牌
      TriggerSkill.create("鬼才", TriggerEvent.AskForRetrial,
        function(_s, room, player, data)
          if not data or #player.hand == 0 then return false end
          local hit = JUDGE_HIT[data.reason]
          -- 只在「自己的判定会命中（对自己不利）」时改判
          local want_miss = (data.player == player) and hit
            and hit(data.judge_card)
          if not want_miss then return false end
          for _, c in ipairs(player.hand) do
            if not hit(c) then
              player:takeCard(c)
              data.judge_card = c
              room:log("%s 发动【鬼才】，以 %s 替换判定牌", player.name, c:displayName())
              return true
            end
          end
          return false
        end, { zh = "鬼才" }),
    },
  },
  {
    name = "夏侯惇", key = "xiahoudun", max_hp = 4, kingdom = "wei",
    skills = {
      -- 刚烈：受到伤害后判定，非红桃则来源弃两张牌，否则受到 1 点伤害
      TriggerSkill.create("刚烈", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.to ~= player or not data.from then return false end
          local src = data.from
          if src == player or not src.alive then return false end
          local j = drawForJudge(room)
          if not j then return false end
          local hits = JUDGE_HIT.ganglie(j)
          room:log("%s 发动【刚烈】，判定 %s %s", player.name, j:displayName(),
            hits and "非红桃，生效" or "红桃，无效")
          table.insert(room.discardPile, j)
          if not hits then return false end
          if not src.alive then return false end
          -- 对齐原版：手牌不足 2 张时不再询问，直接造成伤害
          local dropped = (#src.hand >= 2) and (room:askForDiscard(src, 2) or {}) or {}
          local n = 0
          for _, c in ipairs(dropped) do
            if src:takeCard(c) then
              table.insert(room.discardPile, c)
              n = n + 1
            end
          end
          if n < 2 then
            room:log("%s 无法弃置两张牌，受到 1 点伤害", src.name)
            room:damage(player, src, 1)
          end
          return false
        end, { zh = "刚烈" }),
    },
  },
  {
    name = "张辽", key = "zhangliao", max_hp = 4, kingdom = "wei",
    skills = {
      -- 突袭：摸牌阶段可放弃摸牌，改为获得至多两名其他角色各一张手牌
      TriggerSkill.create("突袭", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "draw" or data.player ~= player then return false end
          if player.skip_draw then return false end
          local victims = {}
          for _, q in ipairs(room:otherAlivePlayers(player)) do
            if #q.hand > 0 then table.insert(victims, q) end
          end
          if #victims == 0 then return false end
          room:log("%s 发动【突袭】，放弃摸牌改为夺取手牌", player.name)
          for i = 1, math.min(2, #victims) do
            local v = victims[i]
            local c = v.hand[1]
            v:takeCard(c)
            table.insert(player.hand, c)
            room:log("%s 夺取 %s 的一张手牌", player.name, v.name)
          end
          return true -- 截断：跳过正常摸牌
        end, { zh = "突袭" }),
    },
  },
  {
    name = "许褚", key = "xuchu", max_hp = 4, kingdom = "wei",
    skills = {
      -- 裸衣：摸牌阶段少摸一张，本回合【杀】/【决斗】伤害 +1
      TriggerSkill.create("裸衣", TriggerEvent.DrawNCards,
        function(_s, room, player, data)
          if not data or data.player ~= player then return false end
          data.n = (data.n or 2) - 1
          player.luoyi = true
          room:log("%s 发动【裸衣】，少摸一张牌，本回合【杀】/【决斗】伤害 +1", player.name)
          return false
        end, { zh = "裸衣" }),
      resetFlag("裸衣·重置", { flag = "luoyi", zh = "裸衣" }),
      TriggerSkill.create("裸衣·增伤", TriggerEvent.DamageCaused,
        function(_s, room, player, data)
          if not player.luoyi then return false end
          if not data or data.from ~= player or not data.card then return false end
          if not (isSlashName(data.card.name) or data.card.name == "duel") then return false end
          data.n = data.n + 1
          room:log("%s 的【裸衣】生效，伤害提升至 %d", player.name, data.n)
          return false
        end, { zh = "裸衣" }),
    },
  },
  {
    name = "郭嘉", key = "guojia", max_hp = 3, kingdom = "wei",
    skills = {
      -- 天妒：判定牌生效后，获得之
      TriggerSkill.create("天妒", TriggerEvent.FinishJudge,
        function(_s, room, player, data)
          if not data or data.player ~= player or not data.judge_card then return false end
          room:log("%s 发动【天妒】，获得判定牌 %s", player.name, data.judge_card:displayName())
          room:obtain(player, data.judge_card)
          return false
        end, { zh = "天妒" }),
      -- 遗计：受到伤害后摸两张牌（原版可分给他人，这里简化为自用）
      TriggerSkill.create("遗计", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.to ~= player then return false end
          room:log("%s 发动【遗计】，摸两张牌", player.name)
          room:drawCards(player, 2)
          return false
        end, { zh = "遗计" }),
    },
  },
  {
    name = "甄姬", key = "zhenji", max_hp = 3, kingdom = "wei",
    skills = {
      singleViewAs("倾国", "dodge", isBlack),
      -- 洛神：回合开始时可反复判定，黑色判定牌收入手中
      TriggerSkill.create("洛神", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "start" or data.player ~= player then return false end
          local got = 0
          for _ = 1, 12 do
            local c = drawForJudge(room)
            if not c then break end
            if not c:isRed() then
              table.insert(player.hand, c)
              got = got + 1
              room:log("%s 的【洛神】判定 %s 黑色，收入手中", player.name, c:displayName())
            else
              table.insert(room.discardPile, c)
              room:log("%s 的【洛神】判定 %s 红色，停止", player.name, c:displayName())
              break
            end
          end
          if got > 0 then
            room:log("%s 发动【洛神】，共获得 %d 张牌", player.name, got)
          end
          return false
        end, { zh = "洛神" }),
    },
  },
  {
    name = "夏侯渊", key = "xiahouyuan", max_hp = 4, kingdom = "wei",
    skills = {
      -- 神速①：跳过判定与摸牌阶段，视为使用一张无距离限制的【杀】
      TriggerSkill.create("神速·壹", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "judge" or data.player ~= player then return false end
          local target = firstInRange(player, room, math.huge)
          if not target then return false end
          room:log("%s 发动【神速】，跳过判定与摸牌阶段，对 %s 使用一张【杀】",
            player.name, target.name)
          room:skipPhase(player, "draw")
          local slash = phantomCard("slash")
          slash.no_distance_limit = true
          room:useCard(player, slash, target)
          return true -- 截断：跳过判定阶段
        end, { zh = "神速" }),
      -- 神速②：弃置一张装备牌跳过出牌阶段，视为使用一张无距离限制的【杀】
      TriggerSkill.create("神速·贰", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.shensu_used then return false end
          -- AI 策略：手里还有【杀】就正常出牌，不白白牺牲出牌阶段
          for _, c in ipairs(player.hand) do
            if isSlashName(c.name) then return false end
          end
          local discard = nil
          for _, c in ipairs(player.hand) do
            if Cards.isEquip(c.name) then discard = c break end
          end
          if not discard then return false end
          local target = firstInRange(player, room, math.huge)
          if not target then return false end
          player:takeCard(discard)
          table.insert(room.discardPile, discard)
          room:log("%s 发动【神速】，弃置【%s】跳过出牌阶段，对 %s 使用一张【杀】",
            player.name, discard:zhName(), target.name)
          local slash = phantomCard("slash")
          slash.no_distance_limit = true
          room:useCard(player, slash, target)
          return true -- 截断：跳过出牌阶段
        end, { zh = "神速" }),
    },
  },
  {
    name = "张郃", key = "zhanghe", max_hp = 4, kingdom = "wei",
    skills = {
      -- 巧变：弃一张手牌跳过一个阶段；跳过摸牌阶段改为夺取至多两人各一张手牌
      TriggerSkill.create("巧变", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.player ~= player then return false end
          local ph = data.phase
          if ph ~= "judge" and ph ~= "draw" and ph ~= "play" and ph ~= "discard" then
            return false
          end
          if #player.hand == 0 then return false end
          -- 分阶段的 AI 策略：只在「跳过该阶段是净收益」时发动
          if ph == "judge" and #player.judges == 0 then
            return false -- 判定区空着，跳过无意义
          elseif ph == "draw" and #player.hand < 2 then
            return false -- 手牌太少，不值得用一张牌换两张
          elseif ph == "play" and firstInRange(player, room) then
            return false -- 还打得到人，不跳过出牌阶段
          elseif ph == "discard" and #player.hand <= player.hp then
            return false -- 本来就不用弃牌
          end
          local c = player.hand[1]
          player:takeCard(c)
          table.insert(room.discardPile, c)
          room:log("%s 发动【巧变】，弃置一张牌跳过%s阶段",
            player.name, PHASE_ZH[ph] or ph)
          if ph == "draw" then
            local victims = {}
            for _, q in ipairs(room:otherAlivePlayers(player)) do
              if #q.hand > 0 then table.insert(victims, q) end
            end
            for i = 1, math.min(2, #victims) do
              local got = victims[i].hand[1]
              victims[i]:takeCard(got)
              table.insert(player.hand, got)
              room:log("%s 获得 %s 的一张手牌", player.name, victims[i].name)
            end
          end
          return true -- 截断：跳过该阶段
        end, { zh = "巧变" }),
    },
  },
  {
    name = "徐晃", key = "xuhuang", max_hp = 4, kingdom = "wei",
    skills = {
      -- 断粮：黑色基本牌/装备牌当【兵粮寸断】，且距离 +1
      singleViewAs("断粮", "supply_shortage", function(c)
        return (not c:isRed())
          and (c.ctype == Card.Type.Basic or c.ctype == Card.Type.Equip)
      end),
      markerSkill("断粮·距离", { extra_dist_supply_shortage = 1 }),
    },
  },
  {
    name = "曹仁", key = "caoren", max_hp = 4, kingdom = "wei",
    skills = {
      -- 据守：回合结束阶段可摸三张牌并翻面
      TriggerSkill.create("据守", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "finish" or data.player ~= player then return false end
          room:log("%s 发动【据守】，摸三张牌并翻面", player.name)
          room:drawCards(player, 3)
          room:turnOver(player)
          return false
        end, { zh = "据守" }),
    },
  },
  {
    name = "典韦", key = "dianwei", max_hp = 4, kingdom = "wei",
    skills = {
      -- 强袭：出牌阶段，失去 1 点体力或弃置武器，对攻击范围内一名角色造成 1 点伤害
      TriggerSkill.create("强袭", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play then return false end
          local target = firstInRange(player, room)
          if not target then return false end
          local w = player:getWeapon()
          if w then
            player.equips.weapon = nil
            table.insert(room.discardPile, w)
            room:log("%s 发动【强袭】，弃置武器【%s】", player.name, w:zhName())
          elseif player.hp > 1 then
            room:log("%s 发动【强袭】，失去 1 点体力", player.name)
            room:loseHp(player, 1)
            if not player.alive or player.hp <= 0 then return false end
          else
            return false -- 无武器且体力不足时不发动
          end
          room:damage(player, target, 1)
          return false
        end, { zh = "强袭" }),
    },
  },
  {
    name = "荀彧", key = "xunyu", max_hp = 3, kingdom = "wei",
    skills = {
      -- 驱虎：出牌阶段与一名体力更多的角色拼点，赢则令其对范围内角色造成 1 点伤害
      TriggerSkill.create("驱虎", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or #player.hand == 0 then return false end
          local t = nil
          for _, q in ipairs(foes(player, room)) do
            if q.hp > player.hp and #q.hand > 0 then t = q break end
          end
          if not t then return false end
          room:log("%s 发动【驱虎】，与 %s 拼点", player.name, t.name)
          if room:pindian(player, t) then
            local wolf = nil
            for _, q in ipairs(foes(player, room)) do
              if q ~= t and room:distance(t, q) <= t:attackRange() then wolf = q break end
            end
            if wolf then
              room:log("%s 拼点获胜，令 %s 对 %s 造成 1 点伤害", player.name, t.name, wolf.name)
              room:damage(t, wolf, 1)
            else
              room:log("%s 拼点获胜，但 %s 攻击范围内无其他角色", player.name, t.name)
            end
          else
            room:log("%s 拼点失败，受到 %s 造成的 1 点伤害", player.name, t.name)
            room:damage(t, player, 1)
          end
          return false
        end, { zh = "驱虎" }),
      -- 节命：受到伤害后，可令一名角色将手牌补至 min(5, 体力上限) 张
      TriggerSkill.create("节命", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.to ~= player or not player.alive then return false end
          local upper = math.min(5, player.max_hp)
          local x = upper - #player.hand
          if x <= 0 then return false end
          room:log("%s 发动【节命】，将手牌补至 %d 张", player.name, upper)
          room:drawCards(player, x)
          return false
        end, { zh = "节命" }),
    },
  },
  {
    name = "曹丕", key = "caopi", max_hp = 3, kingdom = "wei",
    skills = {
      -- 行殇：其他角色死亡时，获得其所有牌
      TriggerSkill.create("行殇", TriggerEvent.Death,
        function(_s, room, player, data)
          local dead = data and data.player
          if not dead or dead == player or not player.alive then return false end
          local n = 0
          for i = #dead.hand, 1, -1 do
            table.insert(player.hand, table.remove(dead.hand, i))
            n = n + 1
          end
          for _, slot in ipairs(EQUIP_SLOTS) do
            if dead.equips[slot] then
              table.insert(player.hand, dead.equips[slot])
              dead.equips[slot] = nil
              n = n + 1
            end
          end
          if n > 0 then
            room:log("%s 发动【行殇】，获得 %s 的 %d 张牌", player.name, dead.name, n)
          end
          return false
        end, { zh = "行殇" }),
      -- 放逐：受到伤害后，令一名其他角色摸 X 张牌并翻面（X 为已损失体力）
      TriggerSkill.create("放逐", TriggerEvent.Damaged,
        function(_s, room, player, data)
          if not data or data.to ~= player then return false end
          local t = nil
          if data.from and data.from ~= player and data.from.alive then t = data.from end
          if not t then
            for _, q in ipairs(foes(player, room)) do t = q break end
          end
          if not t then return false end
          local lost = player.max_hp - player.hp
          room:log("%s 发动【放逐】，%s %s", player.name, t.name,
            lost > 0 and string.format("摸 %d 张牌并翻面", lost) or "被翻面")
          if lost > 0 then room:drawCards(t, lost) end
          room:turnOver(t)
          return false
        end, { zh = "放逐" }),
    },
  },
  {
    name = "乐进", key = "yuejin", max_hp = 4, kingdom = "wei",
    skills = {
      -- 骁果：其他角色结束阶段，可弃一张基本牌令其弃一张装备牌，否则受 1 点伤害
      TriggerSkill.create("骁果", TriggerEvent.EventPhaseStart,
        function(_s, room, player, data)
          if not data or data.phase ~= "finish" then return false end
          local turner = data.player
          if not turner or turner == player or not turner.alive then return false end
          if #player.hand < 2 then return false end
          local basic = nil
          for _, c in ipairs(player.hand) do
            if c.ctype == Card.Type.Basic then basic = c break end
          end
          if not basic then return false end
          local has_equip = false
          for _, slot in ipairs(EQUIP_SLOTS) do
            if turner.equips[slot] then has_equip = true break end
          end
          -- AI 策略：只在能逼掉装备或能压低残血时发动，避免白扔基本牌
          if not has_equip and turner.hp > 2 then return false end
          player:takeCard(basic)
          table.insert(room.discardPile, basic)
          room:log("%s 发动【骁果】，弃置【%s】，要求 %s 弃置一张装备牌",
            player.name, basic:zhName(), turner.name)
          local equip = nil
          for _, slot in ipairs(EQUIP_SLOTS) do
            if turner.equips[slot] then equip = turner.equips[slot] break end
          end
          if equip then
            turner:unequipCard(equip)
            table.insert(room.discardPile, equip)
            room:log("%s 弃置【%s】", turner.name, equip:zhName())
          else
            room:log("%s 无装备牌可弃，受到 1 点伤害", turner.name)
            room:damage(player, turner, 1)
          end
          return false
        end, { zh = "骁果" }),
    },
  },
}

-- 汇总所有已实现的武将
function Generals.all()
  local out = {}
  for _, g in ipairs(Generals.SHU) do table.insert(out, g) end
  for _, g in ipairs(Generals.WEI) do table.insert(out, g) end
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
