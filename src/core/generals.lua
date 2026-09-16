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
local Player = require "src.core.player"
local sk = require "src.core.skill"
local TriggerSkill = sk.TriggerSkill
local ViewAsSkill = sk.ViewAsSkill
local TriggerEvent = sk.TriggerEvent
local Freq = sk.Frequency

-- 阶段触发技能：把「阶段（+本人）」判定提到 can_trigger（征询玩家**之前**）。
-- 否则条件写在 on_trigger 里的话，每个玩家的每个阶段开始都会弹一次
-- 「是否发动【X】」——实测闭月/离间**每轮被问 6 次**。
-- 该技能的触发阶段从原守卫里提取（data.phase ~= "X"），函数体原样保留。
local function phaseTrigger(name, phase, fn, opts, scope, event)
  -- scope: "self"（默认，仅本人该阶段）/ "other"（仅其他角色，如【骁果】【固政】）/ "any"
  -- event: 默认 EventPhaseStart；【固政】【礼让】是 EventPhaseEnd
  local s = TriggerSkill.create(name, event or TriggerEvent.EventPhaseStart, fn, opts)
  scope = scope or "self"
  s.can_trigger = function(_, _, player, data)
    -- phase 为 nil 时不限阶段（【巧变】跨判定/摸牌/出牌/弃牌四个阶段）
    if phase and (not data or data.phase ~= phase) then return false end
    if not data then return false end
    if scope == "self" and data.player ~= player then return false end
    if scope == "other" and data.player == player then return false end
    return true
  end
  return s
end

local Generals = {}

-- 构造单牌转化技：一张符合 filter 的牌 → result_name。
-- opts.hand_only = true 时只认手牌（牌面写「手牌」的技能，如【倾国】）；
-- 默认手牌 + 装备区都可被转化（牌面写「一张XX牌」的技能，如【武圣】）。
local function singleViewAs(name, result_name, filter, opts)
  local s = ViewAsSkill.create(name, {
    zh = name, result_name = result_name, n = 1,
    hand_only = opts and opts.hand_only,
  })
  -- filter 统一按「方法」定义（冒号调用），原始谓词存 predicate；
  -- 否则静态检查会报「定义与调用语法不匹配」（点号/冒号错配踩过多次）。
  s.predicate = filter
  function s:filter(c) return self.predicate(c) end
  function s:view_as(cards)
    if #cards ~= 1 then return nil end
    local src = cards[1]
    if self.predicate and not self.predicate(src) then return nil end
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
local isClub = function(c) return c.suit == Card.Suit.Club end

local EQUIP_SLOTS = { "weapon", "armor", "offensive_horse", "defensive_horse" }
local PHASE_ZH = {
  start = "开始", judge = "判定", draw = "摸牌",
  play = "出牌", discard = "弃牌", finish = "结束",
}

-- 延时锦囊的命中条件（【鬼才】改判时需要独立于 def.judge 的纯函数，
-- 因为 def.judge 会打印判定日志，不能被预演调用）
-- 签名统一为 (room, p, c)：判定要走 p 的过滤技有效花色，
-- 否则【红颜】这类改写花色的技能不会影响判定结果。
local JUDGE_HIT = {
  indulgence = function(room, p, c) return room:effSuit(p, c) ~= Card.Suit.Heart end,
  supply_shortage = function(room, p, c) return room:effSuit(p, c) ~= Card.Suit.Club end,
  lightning = function(room, p, c)
    return room:effSuit(p, c) == Card.Suit.Spade and c.number >= 2 and c.number <= 9
  end,
  ganglie = function(room, p, c) return room:effSuit(p, c) ~= Card.Suit.Heart end,
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

-- 把候选玩家列表转成名字数组 + 名字→玩家映射（askForChoice 选人交互用）
local function nameList(players)
  local names, byName = {}, {}
  for _, q in ipairs(players) do
    names[#names + 1] = q.name
    byName[q.name] = q
  end
  return names, byName
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
      -- 仁德：出牌阶段把任意张手牌交给其他角色；本阶段内给出的牌首次达到
      -- 两张或更多时回复 1 点体力（文档规则：每阶段一次，不是累计三张）
      singleViewAs("仁德", "rende", function() return true end),
      TriggerSkill.create("仁德·回血", TriggerEvent.CardUsed,
        function(_, room, player, data)
          if not data or data.from ~= player then return false end
          local card = data.card
          if not card or card.name ~= "rende" then return false end
          player.rende_count = (player.rende_count or 0) + 1
          if player.rende_count >= 2 and not player.rende_healed then
            player.rende_healed = true
            room:log("%s 发动【仁德】本阶段给出 %d 张牌，回复 1 点体力",
              player.name, player.rende_count)
            room:heal(player, 1)
          end
          return false
        end, { zh = "仁德", internal = true }),
      TriggerSkill.create("仁德·重置", TriggerEvent.EventPhaseEnd,
        function(_, _, player, data)
          if data and data.phase == "play" and data.player == player then
            player.rende_count = 0
            player.rende_healed = false
          end
          return false
        end, { zh = "仁德", internal = true }),
      -- 激将（主公技）：需要【杀】时，可令其他蜀势力角色提供。
      -- 响应类（南蛮/决斗）由 Room:askForCard 的求助钩子覆盖，
      -- 这里额外覆盖「出牌阶段主动出杀」——手里没杀时才麻烦队友。
      markerSkill("激将", { lord_supply = { slash = true } }, Freq.Lord),
      -- can_trigger 决定「值不值得问」：不是主公 / 手里有杀 / 没有同势力队友 /
      -- 出杀次数已用尽时一律不问，避免无意义的弹窗（见 Room:trigger 的注释）
      TriggerSkill.create("激将·出杀", TriggerEvent.EventPhaseStart,
        function(_, room, player, _)
          local t = firstInRange(player, room, room:attackRangeOf(player))
          if not t then return false end
          local slash = room:lordSupply(player, "slash")
          if not slash then return false end
          room:log("%s 发动【激将】，对 %s 使用【杀】", player.name, t.name)
          room:useCard(player, slash, t)
          return false
        end, {
          zh = "激将", frequency = Freq.Lord, internal = false,
          can_trigger = function(_, room, player, data)
            if not (data and data.phase == "play" and data.player == player) then
              return false
            end
            if player.skip_play or player.role ~= "lord" then return false end
            if player.slash_count >= room:slashLimit(player)
              and not room:allowsUnlimitedSlash(player) then return false end
            for _, c in ipairs(player.hand) do
              if isSlashName(c.name) then return false end -- 自己有杀就不麻烦队友
            end
            for _, q in ipairs(room.players) do
              if q ~= player and q.alive and q.kingdom == player.kingdom then
                return true
              end
            end
            return false
          end,
        }),
    },
  },
  {
    -- 体力对齐实体标准版（4 点）；参照的 QSanguosha-Hegemon 源码里是 5 点
    name = "关羽", key = "guanyu", max_hp = 4, kingdom = "shu",
    skills = { singleViewAs("武圣", "slash", isRed) },
  },
  {
    name = "张飞", key = "zhangfei", max_hp = 4, kingdom = "shu",
    skills = { markerSkill("咆哮", { unlimited_slash = true }) },
  },
  {
    name = "诸葛亮", key = "zhugeliang", max_hp = 3, kingdom = "shu",
    skills = {
      -- 观星：准备阶段观看牌堆顶 X 张（X = 存活角色数且至多为 5），
      -- 任意分配回牌堆顶与牌堆底。无交互时保持原序（BOT / headless）。
      phaseTrigger("观星", "start",
        function(_, room, player, data)
          if not data or data.phase ~= "start" or data.player ~= player then
            return false
          end
          local x = math.min(#room:alivePlayers(), 5)
          local cards = {}
          for _ = 1, x do
            if #room.drawPile == 0 then break end
            table.insert(cards, table.remove(room.drawPile))
          end
          if #cards == 0 then return false end
          room:log("%s 发动【观星】，观看牌堆顶 %d 张牌", player.name, #cards)
          local up, down = room:askForGuanxing(player, cards, {})
          -- drawPile 用 table.remove 从尾部取牌，即「尾部 = 牌堆顶」
          for i = #(down or {}), 1, -1 do table.insert(room.drawPile, 1, down[i]) end
          for i = #(up or {}), 1, -1 do table.insert(room.drawPile, up[i]) end
          return false
        end, { zh = "观星" }),
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
        function(_, room, player, data)
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
        end, { zh = "铁骑",
          can_trigger = function(_s, room, player, data)
            return data and data.from == player and data.card ~= nil
            and isSlashName(data.card.name) and #room.drawPile > 0
          end }),
    },
  },
  {
    name = "黄月英", key = "huangyueying", max_hp = 3, kingdom = "shu", female = true,
    skills = {
      markerSkill("奇才", { no_trick_range = true }),
      -- 集智：使用非延时锦囊牌后摸一张
      TriggerSkill.create("集智", TriggerEvent.CardUsed,
        function(_, room, player, data)
          if not data or data.from ~= player or not data.card then return false end
          local def = Cards.get(data.card.name)
          if not def or def.ctype ~= Card.Type.Trick then return false end
          if Cards.isDelayed(data.card.name) then return false end
          room:log("%s 发动【集智】，摸一张牌", player.name)
          room:drawCards(player, 1)
          return false
        end, { zh = "集智",
          can_trigger = function(_s, room, player, data)
            local d = data and data.card and Cards.get(data.card.name)
            return data and data.from == player and d ~= nil
              and d.ctype == Card.Type.Trick
              and not Cards.isDelayed(data.card.name)
          end }),
    },
  },
  {
    name = "黄忠", key = "huangzhong", max_hp = 4, kingdom = "shu",
    skills = {
      -- 烈弓：目标手牌数不小于你的体力值时，此【杀】不可被【闪】响应
      TriggerSkill.create("烈弓", TriggerEvent.TargetChosen,
        function(_, room, player, data)
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
        end, { zh = "烈弓",
          can_trigger = function(_s, room, player, data)
            return data and data.from == player and data.to ~= nil
            and data.card ~= nil and isSlashName(data.card.name)
          end }),
    },
  },
  {
    name = "魏延", key = "weiyan", max_hp = 4, kingdom = "shu",
    skills = {
      -- 狂骨：对距离 1 以内的角色造成 1 点伤害后，回复 1 点体力
      TriggerSkill.create("狂骨", TriggerEvent.Damaged,
        function(_, room, player, data)
          if not data or data.from ~= player or not data.to then return false end
          if room:distance(player, data.to) > 1 then return false end
          if player.hp >= player.max_hp then return false end
          room:log("%s 发动【狂骨】，回复 1 点体力", player.name)
          room:heal(player, 1)
          return false
        end, { zh = "狂骨",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.from == player and data.to ~= nil
          and room:distance(player, data.to) <= 1
          and player.hp < player.max_hp
          end }),
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
        end, { zh = "涅槃",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and not _s.niepan_used
          end, frequency = Freq.Limited }),
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
      -- 再起：摸牌阶段若已受伤，改为亮出牌堆顶 X 张牌（X = 已损失体力），
      -- 每有一张红桃回复 1 点体力（红桃进弃牌堆），其余收入手中，并跳过正常摸牌。
      -- 回血是**概率性**的（取决于翻到几张红桃），不是稳定 +1。
      -- 早期曾被误写成「固定回复 1 点体力」，导致孟获每回合回血正好抵消 BOT
      -- 每回合 1 点输出，形成打不死的死循环（压测卡满 300 回合）。
      TriggerSkill.create("再起", TriggerEvent.DrawNCards,
        function(_, room, player, data)
          -- DrawNCards 以「当前摸牌者」为主语广播，必须确认是自己的摸牌阶段
          if not data or data.player ~= player then return false end
          local x = player.max_hp - player.hp
          if x <= 0 then return false end
          local hearts, others = {}, {}
          for _ = 1, x do
            local c = drawForJudge(room)
            if not c then break end
            if room:effSuit(player, c) == Card.Suit.Heart then
              table.insert(hearts, c)
            else
              table.insert(others, c)
            end
          end
          if #hearts > 0 then
            room:log("%s 发动【再起】，亮出 %d 张中 %d 张红桃，回复 %d 点体力",
              player.name, x, #hearts, #hearts)
            for _, c in ipairs(hearts) do table.insert(room.discardPile, c) end
            room:heal(player, #hearts)
          else
            room:log("%s 发动【再起】，亮出 %d 张无红桃，改为收入手中", player.name, x)
          end
          for _, c in ipairs(others) do table.insert(player.hand, c) end
          data.n = 0
          return false
        end, { zh = "再起",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and player.hp < player.max_hp
          end }),
    },
  },
  {
    name = "祝融", key = "zhurong", max_hp = 4, kingdom = "shu",
    skills = {
      markerSkill("巨象", { savage_immune = true }),
      -- 烈刃：【杀】造成伤害后，可弃置一张手牌对其追加 1 点伤害
      TriggerSkill.create("烈刃", TriggerEvent.Damage,
        function(_, room, player, data)
          if not data or data.from ~= player or not data.to then return false end
          if not data.to.alive or #player.hand == 0 then return false end
          local c = player.hand[1]
          player:takeCard(c)
          table.insert(room.discardPile, c)
          room:log("%s 发动【烈刃】，弃置一张牌对 %s 追加 1 点伤害",
            player.name, data.to.name)
          room:damage(player, data.to, 1)
          return false
        end, { zh = "烈刃",
          can_trigger = function(_s, room, player, data)
            return data and data.from == player and data.to ~= nil
            and data.to.alive and #player.hand > 0
          end }),
    },
  },
  {
    name = "甘夫人", key = "ganfuren", max_hp = 3, kingdom = "shu",
    skills = {
      -- 淑慎：出牌阶段可弃置一张黑色手牌，令一名角色回复 1 点体力
      singleViewAs("淑慎", "shushen", isBlack),
      TriggerSkill.create("淑慎·治疗", TriggerEvent.CardUsed,
        function(_, room, player, data)
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
    function(_, _, player, data)
      if data and data.player == player then player[opts.flag] = false end
      return false
    end, { zh = opts.zh or name, internal = true })
end

Generals.WEI = {
  {
    name = "曹操", key = "caocao", max_hp = 4, kingdom = "wei",
    skills = {
      -- 奸雄：受到伤害后，获得造成伤害的那张牌
      TriggerSkill.create("奸雄", TriggerEvent.Damaged,
        function(_, room, player, data)
          if not data or data.to ~= player or not data.card then return false end
          local card = data.card
          -- 转化技的虚拟牌没有实体，取其来源实体牌；
          -- 【神速】这类凭空生成的牌（phantom）没有来源，不能收（否则凭空多一张）
          if card.phantom then return false end
          local real = (card.virtual and card.subcards and card.subcards[1]) or card
          if not real or real.virtual or real.phantom then return false end
          room:log("%s 发动【奸雄】，获得【%s】", player.name, real:zhName())
          room:obtain(player, real)
          return false
        end, { zh = "奸雄",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.to == player and data.card ~= nil
          and not data.card.phantom
          end }),
      -- 护驾（主公技）：需要【闪】时，可令其他魏势力角色提供
      markerSkill("护驾", { lord_supply = { dodge = true } }, Freq.Lord),
    },
  },
  {
    name = "司马懿", key = "simayi", max_hp = 3, kingdom = "wei",
    skills = {
      -- 反馈：受到伤害后，获得来源的一张牌
      TriggerSkill.create("反馈", TriggerEvent.Damaged,
        function(_, room, player, data)
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
        end, { zh = "反馈",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.to == player and data.from ~= nil
          and data.from ~= player and data.from.alive
          end }),
      -- 鬼才：任意角色的判定牌生效前，可用任意一张手牌替换。
      -- 人类必须看到全部手牌，不把 BOT 的战略判断固化成规则限制；BOT 仍只在
      -- 能改善己方或恶化敌方判定时发动，并只从能达到该结果的牌中选择。
      TriggerSkill.create("鬼才", TriggerEvent.AskForRetrial,
        function(_, room, player, data)
          if not data or not data.player or not data.judge_card or #player.hand == 0 then
            return false
          end
          local cands = {}
          if player.is_human then
            for _, c in ipairs(player.hand) do cands[#cands + 1] = c end
          else
            local hit = JUDGE_HIT[data.reason]
            if not hit then return false end
            local want
            if data.player == player then
              want = false -- 自己的判定：改到不生效
            else
              local hostile = false
              for _, q in ipairs(foes(player, room)) do
                if q == data.player then hostile = true break end
              end
              if not hostile then return false end
              want = true -- 敌人的判定：改到生效
            end
            for _, c in ipairs(player.hand) do
              if hit(room, data.player, c) == want then cands[#cands + 1] = c end
            end
          end
          if #cands == 0 then return false end
          local c = room:askForChooseCard(player, cands,
            string.format("【鬼才】：选择一张手牌替换 %s 的判定牌", data.player.name),
            { giveaway = true }) or cands[1]
          player:takeCard(c)
          data.judge_card = c
          room:log("%s 发动【鬼才】，以 %s 替换 %s 的判定牌",
            player.name, c:displayName(), data.player.name)
          return true
        end, { zh = "鬼才",
          can_trigger = function(_s, room, player, data)
            return data and data.player ~= nil and data.judge_card ~= nil
            and #player.hand > 0
          end }),
    },
  },
  {
    name = "夏侯惇", key = "xiahoudun", max_hp = 4, kingdom = "wei",
    skills = {
      -- 刚烈：受到伤害后判定，非红桃则来源弃两张牌，否则受到 1 点伤害
      TriggerSkill.create("刚烈", TriggerEvent.Damaged,
        function(_, room, player, data)
          if not data or data.to ~= player or not data.from then return false end
          local src = data.from
          if src == player or not src.alive then return false end
          local j = drawForJudge(room)
          if not j then return false end
          local hits = JUDGE_HIT.ganglie(room, player, j)
          room:log("%s 发动【刚烈】，判定 %s %s", player.name, j:displayName(),
            hits and "非红桃，生效" or "红桃，无效")
          table.insert(room.discardPile, j)
          if not hits then return false end
          if not src.alive then return false end
          -- 文档：伤害来源选择一项——弃两张手牌，或受到 1 点伤害。
          -- 手牌不足 2 张时只能受伤；BOT 无响应时保守弃牌。
          local choose_discard = #src.hand >= 2
          if choose_discard then
            local opt_discard, opt_damage = "弃置两张手牌", "受到 1 点伤害"
            local pick = room:askForChoice(src, { opt_discard, opt_damage },
              "【刚烈】：选择一项") or opt_discard
            choose_discard = (pick == opt_discard)
          end
          if not choose_discard then
            room:log("%s 无法/选择不弃牌，受到 1 点伤害", src.name)
            room:damage(player, src, 1)
            return false
          end
          local dropped = room:askForDiscard(src, 2) or {}
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
        end, { zh = "刚烈",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.to == player and data.from ~= nil
          and data.from ~= player and data.from.alive
          end }),
    },
  },
  {
    name = "张辽", key = "zhangliao", max_hp = 4, kingdom = "wei",
    skills = {
      -- 突袭：摸牌阶段可放弃摸牌，改为获得至多两名其他角色各一张手牌
      phaseTrigger("突袭", "draw",
        function(_, room, player, data)
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
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          data.n = (data.n or 2) - 1
          player.luoyi = true
          room:log("%s 发动【裸衣】，少摸一张牌，本回合【杀】/【决斗】伤害 +1", player.name)
          return false
        end, { zh = "裸衣",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player
          end }),
      resetFlag("裸衣·重置", { flag = "luoyi", zh = "裸衣" }),
      TriggerSkill.create("裸衣·增伤", TriggerEvent.DamageCaused,
        function(_, room, player, data)
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
        function(_, room, player, data)
          if not data or data.player ~= player or not data.judge_card then return false end
          room:log("%s 发动【天妒】，获得判定牌 %s", player.name, data.judge_card:displayName())
          room:obtain(player, data.judge_card)
          return false
        end, { zh = "天妒",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and data.judge_card ~= nil
          end }),
      -- 遗计：受到 1 点伤害后，观看牌堆顶两张并逐张交给任意角色
      --（每 1 点伤害触发一次；2 点伤害 = 两次共 4 张，文档口径）
      TriggerSkill.create("遗计", TriggerEvent.Damaged,
        function(_, room, player, data)
          if not data or data.to ~= player then return false end
          local names, byName = nameList(room:alivePlayers())
          for _ = 1, (data.n or 1) do
            local tops = {}
            for _ = 1, 2 do
              if #room.drawPile == 0 then break end
              tops[#tops + 1] = table.remove(room.drawPile)
            end
            for _, c in ipairs(tops) do
              local pick = room:askForChoice(player, names,
                string.format("【遗计】：将【%s】交给谁？", c:displayName()),
                { pick = "self" })
              local to = (pick and byName[pick]) or player
              table.insert(to.hand, c)
              room:log("%s 发动【遗计】，将【%s】交给 %s",
                player.name, c:displayName(), to.name)
            end
          end
          return false
        end, { zh = "遗计",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.to == player
          end }),
    },
  },
  {
    name = "甄姬", key = "zhenji", max_hp = 3, kingdom = "wei", female = true,
    skills = {
      singleViewAs("倾国", "dodge", isBlack, { hand_only = true }),
      -- 洛神：回合开始时可反复判定，黑色判定牌收入手中
      phaseTrigger("洛神", "start",
        function(_, room, player, data)
          if not data or data.phase ~= "start" or data.player ~= player then return false end
          local got = 0
          for _ = 1, 12 do
            local c = drawForJudge(room)
            if not c then break end
            if room:effSuit(player, c) ~= Card.Suit.Heart
              and room:effSuit(player, c) ~= Card.Suit.Diamond then
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
      phaseTrigger("神速·壹", "judge",
        function(_, room, player, data)
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
      phaseTrigger("神速·贰", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.shensu_used then return false end
          -- BOT 策略：手里还有【杀】就正常出牌，不白白牺牲出牌阶段
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
      phaseTrigger("巧变", nil,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          local ph = data.phase
          if ph ~= "judge" and ph ~= "draw" and ph ~= "play" and ph ~= "discard" then
            return false
          end
          if #player.hand == 0 then return false end
          -- 分阶段的 BOT 策略：只在「跳过该阶段是净收益」时发动
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
        end, { zh = "巧变" }, nil, TriggerEvent.EventPhaseStart),
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
      phaseTrigger("据守", "finish",
        function(_, room, player, data)
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
      phaseTrigger("强袭", "play",
        function(_, room, player, data)
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
      phaseTrigger("驱虎", "play",
        function(_, room, player, data)
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
        function(_, room, player, data)
          if not data or data.to ~= player or not player.alive then return false end
          local upper = math.min(5, player.max_hp)
          local x = upper - #player.hand
          if x <= 0 then return false end
          room:log("%s 发动【节命】，将手牌补至 %d 张", player.name, upper)
          room:drawCards(player, x)
          return false
        end, { zh = "节命",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.to == player and player.alive
          end }),
    },
  },
  {
    name = "曹丕", key = "caopi", max_hp = 3, kingdom = "wei",
    skills = {
      -- 行殇：其他角色死亡时，获得其所有牌
      TriggerSkill.create("行殇", TriggerEvent.Death,
        function(_, room, player, data)
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
        end, { zh = "行殇",
          can_trigger = function(_s, room, player, data)
            return data and data.player ~= nil and data.player ~= player and player.alive
          end }),
      -- 放逐：受到伤害后，令一名其他角色摸 X 张牌并翻面（X 为已损失体力）
      TriggerSkill.create("放逐", TriggerEvent.Damaged,
        function(_, room, player, data)
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
        end, { zh = "放逐",
          -- 守卫必须提到 can_trigger：否则场上任何一次伤害都会先播
          -- 横幅与台词，再进效果里判条件（结果什么也没做）
          can_trigger = function(_s, room, player, data)
            return data and data.to == player
          end }),
    },
  },
  {
    name = "乐进", key = "yuejin", max_hp = 4, kingdom = "wei",
    skills = {
      -- 骁果：其他角色结束阶段，可弃一张基本牌令其弃一张装备牌，否则受 1 点伤害
      phaseTrigger("骁果", "finish",
        function(_, room, player, data)
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
          -- BOT 策略：只在能逼掉装备或能压低残血时发动，避免白扔基本牌
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
        end, { zh = "骁果" }, "other"),
    },
  },
}

-- ==================== 吴 ====================
-- 对齐原版 src/package/standard-wu-generals.cpp（WU 001-016）

-- 手牌里「主动打不出去」的废牌，【制衡】换牌的主要对象
-- （旧版制衡的「废牌清单」JUNK 已随技能重写移除：废牌策略现在属于
-- BOT 的 askForDiscard 响应分支，见 bot.lua）

-- 队友（foes 的补集）。注意不能只认「同身份」：主公与忠臣是同阵营但身份不同，
-- 按 q.role == p.role 判断会把忠臣排除掉。
local function allies(p, room)
  local out = {}
  if not room.identity_mode or not p.role then return out end
  local hostile_set = {}
  for _, q in ipairs(foes(p, room)) do hostile_set[q] = true end
  for _, q in ipairs(room.players) do
    -- foes 在没有敌人时会退化成「所有其他人」，此时不能全当队友
    if q ~= p and q.alive and not hostile_set[q] and q.role then
      table.insert(out, q)
    end
  end
  return out
end

-- 临时给玩家挂一个标记技（【天义】拼点胜负产生的回合内效果）
local function grantMarker(p, name, fields)
  for _, s in ipairs(p.extra_skills) do
    if s.name == name then return end
  end
  table.insert(p.extra_skills, markerSkill(name, fields))
end

local function revokeMarker(p, name)
  for i, s in ipairs(p.extra_skills) do
    if s.name == name then table.remove(p.extra_skills, i) return end
  end
end

-- 红颜（锁定技）：黑桃牌视为红桃牌
-- 实现为真正的过滤技：提供 filter_view_filter / filter_view，
-- 由 Room:effSuit 统一消费，因此【天香】与所有判定都会认这个花色。
local function makeHongyan()
  local s = TriggerSkill.create("红颜", {}, nil, {
    zh = "红颜", frequency = Freq.Compulsory,
  })
  s.filter_view_filter = function(card)
    return card.suit == Card.Suit.Spade
  end
  s.filter_view = function(_) return Card.Suit.Heart end
  return s
end

-- 【天香】可用的牌：红桃（【红颜】下黑桃也视为红桃，故走 room:effSuit）
local function isTianxiangCard(room, p, c)
  return room:effSuit(p, c) == Card.Suit.Heart
end

Generals.WU = {
  {
    name = "孙权", key = "sunquan", max_hp = 4, kingdom = "wu",
    skills = {
      -- 制衡：出牌阶段限一次，弃置任意数量的牌（手牌或装备），然后摸等量牌。
      -- 弃哪些由玩家自选（UI 多选 / BOT 换废牌 / AI 候选）；空选 = 不发动。
      TriggerSkill.create("制衡", TriggerEvent.EventPhaseStart,
        function(_, room, player, _)
          local cards = room:askForDiscardAny(player, nil,
            "【制衡】：选择任意张手牌或装备弃置（可不选，摸等量的牌）") or {}
          local n, seen = 0, {}
          for _, c in ipairs(cards) do
            if not seen[c] then
              local zone = player:takeCardAnyZone(c)
              if zone == "hand" or zone == "equip" then
                seen[c] = true
                if zone == "equip" then room:_onEquipLost(player, c) end
                table.insert(room.discardPile, c)
                n = n + 1
              end
            end
          end
          if n == 0 then return false end -- 空选 = 不发动
          player.zhiheng_used = true
          room:log("%s 发动【制衡】，弃置 %d 张牌并摸 %d 张", player.name, n, n)
          room:drawCards(player, n)
          return false
        end, {
          zh = "制衡",
          can_trigger = function(_, _, player, data)
            if not (data and data.phase == "play" and data.player == player) then
              return false
            end
            if player.skip_play or player.zhiheng_used then return false end
            if #player.hand > 0 then return true end
            for _, slot in ipairs(Player.EQUIP_SLOTS) do
              if player.equips[slot] then return true end
            end
            return false -- 手牌或装备区至少有一张牌才询问
          end,
        }),
      resetFlag("制衡·重置", { flag = "zhiheng_used", zh = "制衡" }),
      -- 救援（主公技·锁定）：**每回合限一次**，其他吴势力角色在你濒死时对你
      -- 使用【桃】，你额外回复 1 点体力
      TriggerSkill.create("救援", TriggerEvent.AskForPeaches,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          if player.role ~= "lord" then return false end
          if not data.from or data.from.kingdom ~= "wu" then return false end
          if player.jiuyuan_turn == room.turn_count then return false end
          player.jiuyuan_turn = room.turn_count
          data.n = (data.n or 1) + 1
          room:log("%s 的【救援】生效：吴势力角色的【桃】额外回复 1 点体力",
            player.name)
          return false
        end, { zh = "救援",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and player.role == "lord"
            and data.from ~= nil and data.from.kingdom == "wu"
            and player.jiuyuan_turn ~= room.turn_count
          end, frequency = Freq.Lord }),
    },
  },
  {
    name = "甘宁", key = "ganning", max_hp = 4, kingdom = "wu",
    skills = { singleViewAs("奇袭", "dismantlement", isBlack) },
  },
  {
    name = "吕蒙", key = "lvmeng", max_hp = 4, kingdom = "wu",
    skills = {
      -- 克己：出牌阶段未使用过【杀】则跳过弃牌阶段
      phaseTrigger("克己", "discard",
        function(_, room, player, data)
          if not data or data.phase ~= "discard" or data.player ~= player then return false end
          if player.keji_slash then return false end
          if #player.hand <= player.hp then return false end
          room:log("%s 发动【克己】，本回合未出杀，跳过弃牌阶段", player.name)
          return true -- 截断：跳过弃牌阶段
        end, { zh = "克己" }),
      -- 记录出牌阶段是否用过杀
      TriggerSkill.create("克己·记录", TriggerEvent.PreCardUsed,
        function(_, _, player, data)
          if not data or data.from ~= player or not data.card then return false end
          if isSlashName(data.card.name) and player.phase == "play" then
            player.keji_slash = true
          end
          return false
        end, { zh = "克己" }),
      resetFlag("克己·重置", { flag = "keji_slash", zh = "克己" }),
    },
  },
  {
    name = "黄盖", key = "huanggai", max_hp = 4, kingdom = "wu",
    skills = {
      -- 苦肉：出牌阶段，失去 1 点体力，摸两张牌（每阶段可多次发动）。
      -- 次数不做硬限制；BOT 保留「体力低于 3 时不再自残」的保守策略。
      -- can_trigger：条件不满足时既不做事也不念台词（技能台词挂在 trigger 上）
      TriggerSkill.create("苦肉", TriggerEvent.EventPhaseStart,
        function(_, room, player, _)
          room:log("%s 发动【苦肉】，失去 1 点体力并摸两张牌", player.name)
          room:loseHp(player, 1)
          if not player.alive then return false end
          room:drawCards(player, 2)
          return false
        end, {
          zh = "苦肉",
          can_trigger = function(_, _, player, data)
            if not (data and data.phase == "play" and data.player == player) then
              return false
            end
            return not player.skip_play and player.hp >= 3
          end,
        }),
      resetFlag("苦肉·重置", { flag = "kurou_used", zh = "苦肉" }),
    },
  },
  {
    name = "周瑜", key = "zhouyu", max_hp = 3, kingdom = "wu",
    skills = {
      -- 英姿：摸牌阶段多摸一张
      TriggerSkill.create("英姿", TriggerEvent.DrawNCards,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          data.n = (data.n or 2) + 1
          room:log("%s 发动【英姿】，多摸一张牌", player.name)
          return false
        end, { zh = "英姿",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player
          end }),
      -- 反间：出牌阶段限一次，令一名其他角色获得你的一张手牌并猜花色，
      -- 猜错则受到 1 点伤害。目标与送哪张牌均由周瑜选定。
      phaseTrigger("反间", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.fanjian_used or #player.hand == 0 then return false end
          local others = room:otherAlivePlayers(player)
          if #others == 0 then return false end
          -- 选目标：一名其他角色（BOT/AI 按敌方启发式挑）
          local names, byName = nameList(others)
          local picked = room:askForChoice(player, names,
            "【反间】：选择发动对象（其将获得你的一张手牌并猜花色）", { pick = "enemy" })
          local t = (picked and byName[picked]) or others[1]
          player.fanjian_used = true
          -- 选要送出的手牌（送牌按「最贱优先」给 BOT/AI 兑底）
          local card = room:askForChooseCard(player, player.hand,
            "【反间】：选择一张手牌交给目标", { giveaway = true })
          if not card then card = player.hand[1] end
          player:takeCard(card)
          -- 文档：目标先猜花色，再展示这张牌；无论结果如何都获得此牌
          local SUITS = { Card.Suit.Spade, Card.Suit.Heart, Card.Suit.Club, Card.Suit.Diamond }
          local SUIT_ZH = { "黑桃", "红桃", "梅花", "方块" }
          local guess = room:askForChoice(t, SUIT_ZH,
            string.format("【反间】：猜测 %s 将要给你的一张手牌的花色", player.name))
          local gi = type(guess) == "number" and guess or nil
          if not gi then
            for i, s in ipairs(SUIT_ZH) do if s == guess then gi = i break end end
          end
          if not gi then gi = room:random(4) end -- BOT / 无交互时随机
          table.insert(t.hand, card)
          room:log("%s 发动【反间】，%s 猜「%s」并获得一张手牌（实为 %s）",
            player.name, t.name, SUIT_ZH[gi] or "随机", card:suitString())
          if SUITS[gi] ~= card.suit then
            room:log("%s 猜错花色，受到 1 点伤害", t.name)
            room:damage(player, t, 1)
          else
            room:log("%s 猜中花色，无事发生", t.name)
          end
          return false
        end, { zh = "反间" }),
      resetFlag("反间·重置", { flag = "fanjian_used", zh = "反间" }),
    },
  },
  {
    name = "大乔", key = "daqiao", max_hp = 3, kingdom = "wu", female = true,
    skills = {
      -- 国色：方块手牌当【乐不思蜀】
      singleViewAs("国色", "indulgence", function(c) return c.suit == Card.Suit.Diamond end),
      -- 流离：成为【杀】的目标时，弃一张牌将其转移给攻击范围内的另一名
      -- 角色（不能是使用者）。弃哪张牌、转给谁均由大乔选定。
      TriggerSkill.create("流离", TriggerEvent.TargetConfirming,
        function(_, room, player, data)
          if not data or not data.card or not isSlashName(data.card.name) then return false end
          local mine = false
          for _, t in ipairs(data.to or {}) do
            if t == player then mine = true break end
          end
          if not mine or #player.hand == 0 then return false end
          local cands = {}
          for _, q in ipairs(room.players) do
            if q ~= player and q ~= data.from and q.alive
              and room:distance(player, q) <= player:attackRange() then
              table.insert(cands, q)
            end
          end
          if #cands == 0 then return false end
          -- 弃牌代价：选一张手牌
          local cost = room:askForChooseCard(player, player.hand,
            "【流离】：弃置一张手牌转移此【杀】", { giveaway = true })
          if not cost then cost = player.hand[1] end
          player:takeCard(cost)
          table.insert(room.discardPile, cost)
          -- 转移目标
          local names, byName = nameList(cands)
          local pick = room:askForChoice(player, names,
            "【流离】：将此【杀】转移给谁？", { pick = "enemy" })
          local alt = (pick and byName[pick]) or cands[1]
          room:log("%s 发动【流离】，弃置一张牌将【杀】转移给 %s", player.name, alt.name)
          data.to = { alt }
          return false
        end, { zh = "流离",
          can_trigger = function(_s, room, player, data)
            if not (data and data.card and isSlashName(data.card.name)) then
              return false
            end
            for _, t in ipairs(data.to or {}) do
              if t == player then return true end
            end
            return false
          end }),
    },
  },
  {
    name = "陆逊", key = "luxun", max_hp = 3, kingdom = "wu",
    skills = {
      -- 谦逊（锁定技）：不能成为【顺手牵羊】/【乐不思蜀】的目标
      markerSkill("谦逊", { no_target_tricks = { snatch = true, indulgence = true } }),
      -- 连营：失去最后一张手牌时，可以摸一张牌
      -- （标准版陆逊为【谦逊】+【连营】；此前的【度势】是国战版技能）
      TriggerSkill.create("连营", TriggerEvent.CardsMoveOneTime,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          if data.from_place ~= "hand" or not data.last_handcard then return false end
          if #player.hand > 0 then return false end
          room:log("%s 发动【连营】，摸一张牌", player.name)
          room:drawCards(player, 1)
          return false
        end, { zh = "连营",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and data.from_place == "hand"
            and data.last_handcard == true and #player.hand == 0
          end }),
    },
  },
  {
    name = "孙尚香", key = "sunshangxiang", max_hp = 3, kingdom = "wu", female = true,
    skills = {
      -- 结姻：出牌阶段限一次，弃两张手牌，与一名已受伤的男性角色各回 1 体力。
      -- 目标与弃哪两张牌均由孙尚香选定（askForChoice + askForDiscard 多选）。
      TriggerSkill.create("结姻", TriggerEvent.EventPhaseStart,
        function(_, room, player, _)
          local cands = {}
          for _, q in ipairs(room.players) do
            if q ~= player and q.alive and not q.female and q.hp < q.max_hp then
              table.insert(cands, q)
            end
          end
          if #cands == 0 then return false end
          -- 代价：弃两张手牌（UI 多选 / BOT 挑废牌 / AI 候选；响应不完整则不发动）
          local cost = room:askForDiscard(player, 2) or {}
          local valid = {}
          local seen = {}
          for _, c in ipairs(cost) do
            if not seen[c] then
              for _, hc in ipairs(player.hand) do
                if hc == c then
                  seen[c] = true
                  valid[#valid + 1] = c
                  break
                end
              end
            end
          end
          if #valid < 2 then return false end
          player.jieyin_used = true
          for _, c in ipairs(valid) do
            player:takeCard(c)
            table.insert(room.discardPile, c)
          end
          local names, byName = nameList(cands)
          local pick = room:askForChoice(player, names,
            "【结姻】：选择已受伤的男性角色（各回复 1 点体力）", { pick = "ally" })
          local t = (pick and byName[pick]) or cands[1]
          room:log("%s 发动【结姻】，与 %s 各回复 1 点体力", player.name, t.name)
          room:heal(player, 1)
          room:heal(t, 1)
          return false
        end, {
          zh = "结姻",
          can_trigger = function(_, room, player, data)
            if not (data and data.phase == "play" and data.player == player) then
              return false
            end
            if player.skip_play or player.jieyin_used or #player.hand < 2 then
              return false
            end
            for _, q in ipairs(room and room.players or {}) do
              if q ~= player and q.alive and not q.female and q.hp < q.max_hp then
                return true
              end
            end
            return false
          end,
        }),
      resetFlag("结姻·重置", { flag = "jieyin_used", zh = "结姻" }),
      -- 枭姬：失去装备区的牌后摸两张
      TriggerSkill.create("枭姬", TriggerEvent.CardsMoveOneTime,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          if data.from_place ~= "equip" then return false end
          room:log("%s 发动【枭姬】，失去装备后摸两张牌", player.name)
          room:drawCards(player, 2)
          return false
        end, { zh = "枭姬",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and data.from_place == "equip"
          end }),
    },
  },
  {
    name = "孙坚", key = "sunjian", max_hp = 4, kingdom = "wu",
    skills = {
      -- 英魂：回合开始若已受伤，令一名其他角色摸 X 张牌后弃 1 张（X = 已损失体力）
      phaseTrigger("英魂", "start",
        function(_, room, player, data)
          if not data or data.phase ~= "start" or data.player ~= player then return false end
          local x = player.max_hp - player.hp
          if x <= 0 then return false end
          local t = nil
          for _, q in ipairs(allies(player, room)) do t = q break end
          if not t then return false end
          room:log("%s 发动【英魂】，%s 摸 %d 张牌后弃 1 张", player.name, t.name, x)
          room:drawCards(t, x)
          local dropped = room:askForDiscard(t, 1) or {}
          for _, c in ipairs(dropped) do
            if t:takeCard(c) then table.insert(room.discardPile, c) end
          end
          return false
        end, { zh = "英魂" }),
    },
  },
  {
    name = "小乔", key = "xiaoqiao", max_hp = 3, kingdom = "wu", female = true,
    skills = {
      -- 红颜（锁定技）：黑桃牌视为红桃牌
      makeHongyan(),
      -- 天香：受到伤害时弃一张红桃手牌，将此伤害转移给另一名角色，其再摸 X 张牌
      TriggerSkill.create("天香", TriggerEvent.DamageInflicted,
        function(_, room, player, data)
          if not data or data.to ~= player then return false end
          local idx = nil
          for i, c in ipairs(player.hand) do
            if isTianxiangCard(room, player, c) then idx = i break end
          end
          if not idx then return false end
          local t = nil
          for _, q in ipairs(foes(player, room)) do t = q break end
          if not t then return false end
          local c = player.hand[idx]
          player:takeCard(c)
          table.insert(room.discardPile, c)
          room:log("%s 发动【天香】，将此伤害转移给 %s", player.name, t.name)
          room:damage(data.from, t, data.n, data.nature, data.card)
          local lost = t.max_hp - t.hp
          if lost > 0 and t.alive then
            room:log("%s 因【天香】摸 %d 张牌", t.name, lost)
            room:drawCards(t, lost)
          end
          return true -- 截断：原伤害不再结算
        end, { zh = "天香",
          can_trigger = function(_s, room, player, data)
            return data and data.to == player
          end }),
    },
  },
  {
    name = "太史慈", key = "taishici", max_hp = 4, kingdom = "wu",
    skills = {
      -- 天义：出牌阶段与一名角色拼点，赢则杀无距离限制且次数不限，输则本回合不能出杀
      phaseTrigger("天义", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.tianyi_used or #player.hand == 0 then return false end
          local t = nil
          for _, q in ipairs(foes(player, room)) do
            if #q.hand > 0 then t = q break end
          end
          if not t then return false end
          player.tianyi_used = true
          room:log("%s 发动【天义】，与 %s 拼点", player.name, t.name)
          if room:pindian(player, t) then
            room:log("%s 拼点获胜：本回合【杀】无距离限制且次数不限", player.name)
            grantMarker(player, "天义·胜", {
              unlimited_slash = true, slash_no_distance = true, slash_extra_target = true,
            })
          else
            room:log("%s 拼点失败：本回合不能使用【杀】", player.name)
            grantMarker(player, "天义·负", { no_slash = true })
          end
          return false
        end, { zh = "天义" }),
      resetFlag("天义·重置", { flag = "tianyi_used", zh = "天义" }),
      TriggerSkill.create("天义·清除", TriggerEvent.TurnStart,
        function(_, _, player, data)
          if data and data.player == player then
            revokeMarker(player, "天义·胜")
            revokeMarker(player, "天义·负")
          end
          return false
        end, { zh = "天义" }),
    },
  },
  {
    name = "周泰", key = "zhoutai", max_hp = 4, kingdom = "wu",
    skills = {
      -- 不屈：濒死时翻出牌堆顶一张牌作为「创」，点数不重复则免死并回复至 1 点体力
      TriggerSkill.create("不屈", TriggerEvent.Dying,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          local c = drawForJudge(room)
          if not c then return false end
          player.buqu = player.buqu or {}
          local dup = false
          for _, b in ipairs(player.buqu) do
            if b == c.number then dup = true break end
          end
          -- 「创」牌实体进弃牌堆以保证牌数守恒，这里只记点数
          table.insert(room.discardPile, c)
          if dup then
            room:log("%s 的【不屈】翻出 %s%d，点数重复，无法免死",
              player.name, c:suitString(), c.number)
            return false
          end
          table.insert(player.buqu, c.number)
          room:log("%s 发动【不屈】，翻出 %s%d 点数不重复，免于死亡并回复至 1 点体力",
            player.name, c:suitString(), c.number)
          player.hp = 1
          return true -- 截断濒死结算
        end, { zh = "不屈",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player
          end }),
    },
  },
  {
    name = "鲁肃", key = "lusu", max_hp = 3, kingdom = "wu",
    skills = {
      -- 好施：摸牌阶段多摸两张；若手牌多于 5 张，将一半交给手牌最少的其他角色
      TriggerSkill.create("好施", TriggerEvent.DrawNCards,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          data.n = (data.n or 2) + 2
          player.haoshi = true
          room:log("%s 发动【好施】，多摸两张牌", player.name)
          return false
        end, { zh = "好施",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player
          end }),
      TriggerSkill.create("好施·散财", TriggerEvent.AfterDrawNCards,
        function(_, room, player, data)
          if not data or data.player ~= player or not player.haoshi then return false end
          player.haoshi = false
          if #player.hand <= 5 then return false end
          local beggar = nil
          for _, q in ipairs(room:otherAlivePlayers(player)) do
            if not beggar or #q.hand < #beggar.hand then beggar = q end
          end
          if not beggar then return false end
          local n = math.floor(#player.hand / 2)
          room:log("%s 的【好施】生效，将 %d 张手牌交给 %s", player.name, n, beggar.name)
          for _ = 1, n do
            local c = table.remove(player.hand, 1)
            if c then table.insert(beggar.hand, c) end
          end
          return false
        end, { zh = "好施" }),
      -- 缔盟：弃 X 张手牌，交换两名手牌数相差 X 的其他角色的手牌
      phaseTrigger("缔盟", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.dimeng_used or #player.hand < 2 then return false end
          -- BOT 策略：把队友的少牌和敌人的多牌对调（经典用法）
          local mate, foe = nil, nil
          for _, q in ipairs(allies(player, room)) do
            if not mate or #q.hand < #mate.hand then mate = q end
          end
          for _, q in ipairs(foes(player, room)) do
            if not foe or #q.hand > #foe.hand then foe = q end
          end
          if not mate or not foe or mate == foe then return false end
          local k = #foe.hand - #mate.hand
          if k <= 0 or k > #player.hand then return false end
          player.dimeng_used = true
          for _ = 1, k do
            table.insert(room.discardPile, table.remove(player.hand, 1))
          end
          room:log("%s 发动【缔盟】，弃 %d 张牌交换 %s 与 %s 的手牌",
            player.name, k, mate.name, foe.name)
          mate.hand, foe.hand = foe.hand, mate.hand
          return false
        end, { zh = "缔盟" }),
      resetFlag("缔盟·重置", { flag = "dimeng_used", zh = "缔盟" }),
    },
  },
  {
    name = "二张", key = "erzhang", max_hp = 3, kingdom = "wu",
    skills = {
      -- 直谏：出牌阶段将一张装备牌置于一名其他角色的装备区，然后摸一张牌
      phaseTrigger("直谏", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.zhijian_used then return false end
          local equip = nil
          for _, c in ipairs(player.hand) do
            if Cards.isEquip(c.name) then equip = c break end
          end
          if not equip then return false end
          local t = nil
          for _, q in ipairs(allies(player, room)) do t = q break end
          if not t then return false end
          local def = Cards.get(equip.name)
          local slot = def and def.equip or "weapon"
          if t.equips[slot] then return false end -- 目标该槽位已有装备
          player.zhijian_used = true
          player:takeCard(equip)
          local old = t:equipCard(equip, slot)
          if old then
            room:_onEquipLost(t, old)
            table.insert(room.discardPile, old)
          end
          room:log("%s 发动【直谏】，将【%s】装备给 %s 并摸一张牌",
            player.name, equip:zhName(), t.name)
          room:drawCards(player, 1)
          return false
        end, { zh = "直谏" }),
      resetFlag("直谏·重置", { flag = "zhijian_used", zh = "直谏" }),
      -- 固政：其他角色弃牌阶段结束时，将其弃牌中的一张还给他，其余收入自己手牌
      phaseTrigger("固政", "discard",
        function(_, room, player, data)
          if not data or data.phase ~= "discard" then return false end
          local turner = data.player
          if not turner or turner == player then return false end
          if room.last_discard_player ~= turner then return false end
          local cards = room.last_discarded or {}
          if #cards == 0 then return false end
          local take = function(c)
            for i, x in ipairs(room.discardPile) do
              if x == c then table.remove(room.discardPile, i) return true end
            end
            return false
          end
          local back = table.remove(cards, 1)
          if take(back) then table.insert(turner.hand, back) end
          for _, c in ipairs(cards) do
            -- 同样只在成功摘出时才收牌，避免重复登记
            if take(c) then table.insert(player.hand, c) end
          end
          room:log("%s 发动【固政】，归还 %s 一张牌并获得其余 %d 张",
            player.name, turner.name, #cards)
          room.last_discarded = {}
          return false
        end, { zh = "固政" }, "other", TriggerEvent.EventPhaseEnd),
    },
  },
  {
    name = "丁奉", key = "dingfeng", max_hp = 4, kingdom = "wu",
    skills = {
      -- 短兵（锁定技）：【杀】可额外指定一名距离 1 以内的角色
      markerSkill("短兵", { slash_extra_target = true }),
      -- 奋迅：出牌阶段弃一张牌，令本回合与一名角色的距离固定为 1
      phaseTrigger("奋迅", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.fenxun_used or #player.hand == 0 then return false end
          local t, far = nil, 1
          for _, q in ipairs(foes(player, room)) do
            local d = room:distance(player, q)
            if d > far then t, far = q, d end
          end
          if not t then return false end
          player.fenxun_used = true
          local c = table.remove(player.hand, 1)
          table.insert(room.discardPile, c)
          player.fixed_distance = player.fixed_distance or {}
          player.fixed_distance[t] = 1
          room:log("%s 发动【奋迅】，与 %s 的距离视为 1（原为 %d）", player.name, t.name, far)
          return false
        end, { zh = "奋迅" }),
      resetFlag("奋迅·重置", { flag = "fenxun_used", zh = "奋迅" }),
      TriggerSkill.create("奋迅·清除", TriggerEvent.TurnStart,
        function(_, _, player, data)
          if data and data.player == player then player.fixed_distance = nil end
          return false
        end, { zh = "奋迅" }),
    },
  },
}

-- ==================== 群 ====================
-- 对齐原版 src/package/standard-qun-generals.cpp（QUN 001-018）
--
-- 注意：这个 QSanguosha 分支是**国战版**，群雄里有几个技能是国战专属机制
-- （明置/暗置武将、势力结盟）。邹氏的【祸水】【倾城】完全建立在「武将明置」
-- 之上，标准身份局没有对应概念，暂以标记技占位并在下方注明。

-- 双牌转化技：两张满足 filter_pair 的手牌合成一张（【乱击】两张同花色→万箭齐发）
local function pairViewAs(name, result_name, filter_pair)
  local s = ViewAsSkill.create(name, { zh = name, result_name = result_name, n = 2 })
  function s:filter_pair(a, b) return filter_pair(a, b) end
  function s:view_as(cards)
    if #cards ~= 2 then return nil end
    if not self:filter_pair(cards[1], cards[2]) then return nil end
    local def = Cards.get(self.result_name)
    local c = Card.create(-1, self.result_name, cards[1].suit, cards[1].number,
      def and def.ctype or Card.Type.Trick)
    c.virtual = true
    c.subcards = { cards[1], cards[2] }
    return c
  end
  return s
end

-- 只收集手牌里的装备/弃牌（用于【狂斧】等需要选装备的场景）
local function firstEquipOf(p)
  for _, slot in ipairs(EQUIP_SLOTS) do
    if p.equips[slot] then return p.equips[slot], slot end
  end
  return nil, nil
end

-- 判定一张牌的花色结果（【悲歌】分四种花色）
local function beigeEffect(room, _, victim, from, card)
  -- 判定属于受害者，走受害者的过滤技（如【红颜】）
  local suit = room:effSuit(victim, card)
  if suit == Card.Suit.Heart then
    room:log("【悲歌】判定红桃，%s 回复 1 点体力", victim.name)
    room:heal(victim, 1)
  elseif suit == Card.Suit.Diamond then
    room:log("【悲歌】判定方块，%s 摸两张牌", victim.name)
    room:drawCards(victim, 2)
  elseif suit == Card.Suit.Club then
    if from and from.alive and #from.hand >= 2 then
      local dropped = room:askForDiscard(from, 2) or {}
      local n = 0
      for _, c in ipairs(dropped) do
        if from:takeCard(c) then table.insert(room.discardPile, c) n = n + 1 end
      end
      room:log("【悲歌】判定梅花，%s 弃置 %d 张牌", from.name, n)
    end
  elseif suit == Card.Suit.Spade then
    if from and from.alive then
      room:log("【悲歌】判定黑桃，%s 被翻面", from.name)
      room:turnOver(from)
    end
  end
end

Generals.QUN = {
  {
    name = "华佗", key = "huatuo", max_hp = 3, kingdom = "qun",
    skills = {
      -- 急救：回合外，红色手牌当【桃】使用
      (function()
        local s = singleViewAs("急救", "peach", isRed)
        s.only_outside_turn = true
        return s
      end)(),
      -- 青囊：出牌阶段限一次，弃一张手牌令一名已受伤角色（含自己）回 1 体力。
      -- 目标与弃哪张牌均由华佗选定；不再限定「损失 ≥2 体力」才可发动。
      TriggerSkill.create("青囊", TriggerEvent.EventPhaseStart,
        function(_, room, player, _)
          local cands = {}
          for _, q in ipairs(room:alivePlayers()) do
            if q.hp < q.max_hp then table.insert(cands, q) end
          end
          if #cands == 0 then return false end
          -- 代价：弃一张手牌
          local cost = room:askForChooseCard(player, player.hand,
            "【青囊】：弃置一张手牌", { giveaway = true })
          if not cost then cost = player.hand[1] end
          player.qingnang_used = true
          player:takeCard(cost)
          table.insert(room.discardPile, cost)
          -- 目标：任意已受伤角色（含自己）
          local names, byName = nameList(cands)
          local pick = room:askForChoice(player, names,
            "【青囊】：选择回复 1 点体力的角色", { pick = "ally" })
          local t = (pick and byName[pick]) or cands[1]
          room:log("%s 发动【青囊】，%s 回复 1 点体力", player.name, t.name)
          room:heal(t, 1)
          return false
        end, {
          zh = "青囊",
          can_trigger = function(_, room, player, data)
            if not (data and data.phase == "play" and data.player == player) then
              return false
            end
            if player.skip_play or player.qingnang_used or #player.hand == 0 then
              return false
            end
            for _, q in ipairs(room:alivePlayers()) do
              if q.hp < q.max_hp then return true end
            end
            return false
          end,
        }),
      resetFlag("青囊·重置", { flag = "qingnang_used", zh = "青囊" }),
    },
  },
  {
    -- 同上：对齐实体标准版（4 点），Hegemon 源码为 5 点
    name = "吕布", key = "lvbu", max_hp = 4, kingdom = "qun",
    skills = { markerSkill("无双", { wushuang = true }) },
  },
  {
    name = "貂蝉", key = "diaochan", max_hp = 3, kingdom = "qun", female = true,
    skills = {
      -- 离间：出牌阶段限一次，弃一张牌令一名男性角色对另一名男性角色使用【决斗】
      phaseTrigger("离间", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or player.lijian_used or #player.hand == 0 then return false end
          local males = {}
          for _, q in ipairs(room.players) do
            if q ~= player and q.alive and not q.female then table.insert(males, q) end
          end
          if #males < 2 then return false end
          player.lijian_used = true
          -- 弃牌代价：选一张手牌
          local cost = room:askForChooseCard(player, player.hand,
            "【离间】：弃置一张手牌", { giveaway = true })
          if not cost then cost = player.hand[1] end
          player:takeCard(cost)
          table.insert(room.discardPile, cost)
          -- 选两名男性及方向（谁对谁用决斗），均由貂蝉选定
          local namesA, byNameA = nameList(males)
          local pickA = room:askForChoice(player, namesA,
            "【离间】：选择使用【决斗】的男性角色", { pick = "enemy" })
          local a = (pickA and byNameA[pickA]) or males[1]
          local rest = {}
          for _, q in ipairs(males) do
            if q ~= a then rest[#rest + 1] = q end
          end
          local namesB, byNameB = nameList(rest)
          local pickB = room:askForChoice(player, namesB,
            "【离间】：选择【决斗】的目标", { pick = "enemy" })
          local b = (pickB and byNameB[pickB]) or rest[1]
          room:log("%s 发动【离间】，令 %s 对 %s 使用【决斗】", player.name, a.name, b.name)
          local duel = phantomCard("duel")
          duel.no_nullify = true -- 此【决斗】不能被【无懈可击】响应
          room:useCard(a, duel, b)
          return false
        end, { zh = "离间" }),
      resetFlag("离间·重置", { flag = "lijian_used", zh = "离间" }),
      -- 闭月：结束阶段摸一张牌
      phaseTrigger("闭月", "finish",
        function(_, room, player, data)
          if not data or data.phase ~= "finish" or data.player ~= player then return false end
          room:log("%s 发动【闭月】，摸一张牌", player.name)
          room:drawCards(player, 1)
          return false
        end, { zh = "闭月" }),
    },
  },
  {
    name = "袁绍", key = "yuanshao", max_hp = 4, kingdom = "qun",
    skills = {
      -- 乱击：两张花色相同的手牌当【万箭齐发】
      pairViewAs("乱击", "archery_attack",
        function(a, b) return a.suit == b.suit end),
    },
  },
  {
    name = "颜良文丑", key = "yanliangwenchou", max_hp = 4, kingdom = "qun",
    skills = {
      -- 双雄：摸牌阶段放弃摸牌改为判定，获得判定牌，本回合可按判定颜色把手牌当【决斗】
      phaseTrigger("双雄", "draw",
        function(_, room, player, data)
          if not data or data.phase ~= "draw" or data.player ~= player then return false end
          if player.skip_draw then return false end
          local c = drawForJudge(room)
          if not c then return false end
          table.insert(player.hand, c)
          -- 1 = 该用黑色牌当决斗，2 = 该用红色牌
          local suit = room:effSuit(player, c)
          player.shuangxiong = (suit == Card.Suit.Heart or suit == Card.Suit.Diamond) and 2 or 1
          room:log("%s 发动【双雄】，判定 %s，本回合可将%s色手牌当【决斗】",
            player.name, c:displayName(), player.shuangxiong == 1 and "黑" or "红")
          return true -- 截断：跳过正常摸牌
        end, { zh = "双雄" }),
      resetFlag("双雄·重置", { flag = "shuangxiong", zh = "双雄" }),
      (function()
        local s = ViewAsSkill.create("双雄",
          { zh = "双雄", result_name = "duel", n = 1, hand_only = true })
        -- filter 由 Room:viewAsCandidates 调用，第二个参数是技能持有者
        function s:filter(c, p)
          local v = p and p.shuangxiong
          if v ~= 1 and v ~= 2 then return false end
          return (v == 1 and not c:isRed()) or (v == 2 and c:isRed())
        end
        function s:view_as(cards)
          if #cards ~= 1 then return nil end
          local c = Card.create(-1, "duel", cards[1].suit, cards[1].number, Card.Type.Trick)
          c.virtual = true
          c.subcards = { cards[1] }
          return c
        end
        return s
      end)(),
    },
  },
  {
    name = "贾诩", key = "jiaxu", max_hp = 3, kingdom = "qun",
    skills = {
      -- 完杀（锁定技）：你的回合内，只有你自己能使用【桃】救人
      markerSkill("完杀", { wansha = true }),
      -- 帷幕（锁定技）：不能成为黑色锦囊牌的目标
      markerSkill("帷幕", { no_black_trick = true }),
      -- 乱武（限定技）：令所有其他角色各对距离最近的角色使用【杀】，否则失去 1 点体力
      phaseTrigger("乱武", "play",
        function(s, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or s.luanwu_used then return false end
          s.luanwu_used = true
          room:log("%s 发动【乱武】（限定技），所有其他角色需出【杀】否则失去体力",
            player.name)
          for _, q in ipairs(room:otherAlivePlayers(player)) do
            local near = nil
            for _, t in ipairs(room.players) do
              if t ~= q and t.alive then
                if not near or room:distance(q, t) < room:distance(q, near) then near = t end
              end
            end
            local slash = nil
            for _, c in ipairs(q.hand) do
              if isSlashName(c.name) then slash = c break end
            end
            if slash and near then
              room:log("%s 对 %s 使用【杀】", q.name, near.name)
              q:takeCard(slash)
              table.insert(room.discardPile, slash)
              room:_resolveSlash(q, near, slash)
            elseif not (near and slash) then
              room:log("%s 无法使用【杀】，失去 1 点体力", q.name)
              room:loseHp(q, 1)
            end
          end
          return false
        end, { zh = "乱武", frequency = Freq.Limited }),
    },
  },
  {
    name = "庞德", key = "pangde", max_hp = 4, kingdom = "qun",
    skills = {
      markerSkill("马术", { distance_mod = -1 }),
      -- 猛进：你的【杀】被【闪】抵消后，可弃置目标的一张牌
      TriggerSkill.create("猛进", TriggerEvent.SlashMissed,
        function(_, room, player, data)
          if not data or data.from ~= player or not data.to then return false end
          local t = data.to
          if not t.alive then return false end
          local card = nil
          if #t.hand > 0 then
            card = t.hand[1]
            t:takeCard(card)
          else
            local e, slot = firstEquipOf(t)
            if e then t.equips[slot] = nil card = e end
          end
          if not card then return false end
          table.insert(room.discardPile, card)
          room:log("%s 发动【猛进】，弃置 %s 的【%s】", player.name, t.name, card:zhName())
          return false
        end, { zh = "猛进",
          can_trigger = function(_s, room, player, data)
            return data and data.from == player and data.to ~= nil and data.to.alive
          end }),
    },
  },
  {
    name = "张角", key = "zhangjiao", max_hp = 3, kingdom = "qun",
    skills = {
      -- 雷击：你打出【闪】后，可令一名角色判定，黑桃则受到 2 点雷伤害
      TriggerSkill.create("雷击", TriggerEvent.CardResponded,
        function(_, room, player, data)
          if not data or data.player ~= player or not data.card then return false end
          if data.card.name ~= "dodge" then return false end
          local t = nil
          for _, q in ipairs(foes(player, room)) do t = q break end
          if not t then return false end
          local j = drawForJudge(room)
          if not j then return false end
          table.insert(room.discardPile, j)
          room:log("%s 发动【雷击】，%s 判定 %s", player.name, t.name, j:displayName())
          -- 走有效花色：目标的【红颜】能改写判定结果
          if room:effSuit(t, j) == Card.Suit.Spade then
            room:log("判定为黑桃，%s 受到 2 点雷伤害", t.name)
            room:damage(player, t, 2, "thunder")
          end
          return false
        end, { zh = "雷击",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and data.card ~= nil
            and data.card.name == "dodge"
          end }),
      -- 鬼道：判定牌生效前，可用一张黑色手牌替换（并获得原判定牌）
      TriggerSkill.create("鬼道", TriggerEvent.AskForRetrial,
        function(_, room, player, data)
          if not data then return false end
          local black = nil
          for _, c in ipairs(player.hand) do
            if not c:isRed() then black = c break end
          end
          if not black then return false end
          -- BOT 策略：只在对自己有利时改判（参照【鬼才】的判定表）
          local hit = JUDGE_HIT[data.reason]
          if hit and data.player == player
            and not hit(room, player, data.judge_card) then return false end
          player:takeCard(black)
          data.judge_card = black
          -- 旧判定牌由引擎交给张角（引擎此时才把它放入弃牌堆，避免重复登记）
          data.obtain_old = true
          data.replacer = player
          room:log("%s 发动【鬼道】，以 %s 替换判定牌并获得原判定牌",
            player.name, black:displayName())
          return true
        end, { zh = "鬼道",
          can_trigger = function(_s, room, player, data)
            if not (data and data.judge_card) then return false end
            for _, c in ipairs(player.hand) do
              if not c:isRed() then return true end
            end
            return false
          end }),
    },
  },
  {
    name = "蔡文姬", key = "caiwenji", max_hp = 3, kingdom = "qun", female = true,
    skills = {
      -- 悲歌：一名角色受到【杀】的伤害后，可弃一张牌令其判定，按花色结算
      TriggerSkill.create("悲歌", TriggerEvent.Damage,
        function(_, room, player, data)
          if not data or not data.card or not isSlashName(data.card.name) then return false end
          if not data.to or data.to == player or #player.hand == 0 then return false end
          table.insert(room.discardPile, table.remove(player.hand, 1))
          local j = drawForJudge(room)
          if not j then return false end
          table.insert(room.discardPile, j)
          room:log("%s 发动【悲歌】，%s 判定 %s", player.name, data.to.name, j:displayName())
          beigeEffect(room, player, data.to, data.from, j)
          return false
        end, { zh = "悲歌",
          can_trigger = function(_s, room, player, data)
            return data and data.card ~= nil and isSlashName(data.card.name)
            and data.to ~= nil and data.to ~= player and #player.hand > 0
          end }),
      -- 断肠（锁定技）：你死亡时，令杀死你的角色失去所有技能
      TriggerSkill.create("断肠", TriggerEvent.Death,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          local killer = data.killer
          if not killer or killer == player or not killer.alive then return false end
          if not killer.general then return false end
          killer.lost_skills = killer.general.skills
          killer.general.skills = {}
          room:log("%s 发动【断肠】，%s 失去所有技能", player.name, killer.name)
          return false
        end, { zh = "断肠",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player
          end }),
    },
  },
  {
    name = "马腾", key = "mateng", max_hp = 4, kingdom = "qun",
    skills = {
      markerSkill("马术", { distance_mod = -1 }),
      -- 雄异（限定技）：令所有队友各摸三张牌；若你已受伤则回复 1 点体力
      phaseTrigger("雄异", "play",
        function(s, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or s.xiongyi_used then return false end
          local mates = allies(player, room)
          if #mates == 0 and player.hp >= player.max_hp then return false end
          s.xiongyi_used = true
          room:log("%s 发动【雄异】（限定技）", player.name)
          for _, q in ipairs(mates) do room:drawCards(q, 3) end
          room:drawCards(player, 3)
          if player.hp < player.max_hp then
            room:log("%s 已受伤，回复 1 点体力", player.name)
            room:heal(player, 1)
          end
          return false
        end, { zh = "雄异", frequency = Freq.Limited }),
    },
  },
  {
    name = "孔融", key = "kongrong", max_hp = 3, kingdom = "qun",
    skills = {
      -- 名士（锁定技）：伤害来源的手牌数不少于你时，此伤害 -1
      -- 注：国战原版的条件是「来源未明置武将」，标准身份局没有该概念，
      -- 这里改用标准版【名士】的常见条件。
      TriggerSkill.create("名士", TriggerEvent.DamageInflicted,
        function(_, room, player, data)
          if not data or data.to ~= player or not data.from then return false end
          if #data.from.hand < #player.hand then return false end
          data.n = data.n - 1
          if data.n < 1 then
            room:log("%s 的【名士】使伤害降为 0", player.name)
            return true
          end
          room:log("%s 的【名士】生效，伤害降为 %d", player.name, data.n)
          return false
        end, { zh = "名士",
          can_trigger = function(_s, room, player, data)
            return data and data.to == player and data.from ~= nil
            and #data.from.hand >= #player.hand
          end }),
      -- 礼让：弃牌阶段结束后，可将弃置的牌分配给其他角色
      phaseTrigger("礼让", "discard",
        function(_, room, player, data)
          if not data or data.phase ~= "discard" or data.player ~= player then return false end
          local cards = room.last_discarded or {}
          if #cards == 0 then return false end
          local others = room:otherAlivePlayers(player)
          if #others == 0 then return false end
          -- BOT 策略：只让出一张。把弃牌全送出去会养肥对手的手牌数，
          -- 反过来触发【名士】的减伤条件，把自己变成打不死的僵局源头。
          room:log("%s 发动【礼让】，将一张弃牌让给其他角色", player.name)
          cards = { cards[1] }
          for i, c in ipairs(cards) do
            -- 只有真正从弃牌堆摘出来的牌才能进手牌，否则会造成同一张牌被登记两次
            local got = false
            for k, x in ipairs(room.discardPile) do
              if x == c then table.remove(room.discardPile, k) got = true break end
            end
            if got then table.insert(others[((i - 1) % #others) + 1].hand, c) end
          end
          room.last_discarded = {}
          return false
        end, { zh = "礼让" }, "self", TriggerEvent.EventPhaseEnd),
    },
  },
  {
    name = "纪灵", key = "jiling", max_hp = 4, kingdom = "qun",
    skills = {
      -- 双刃：出牌阶段开始时与一名角色拼点，赢则视为对其使用【杀】；输则跳过出牌阶段
      phaseTrigger("双刃", "play",
        function(_, room, player, data)
          if not data or data.phase ~= "play" or data.player ~= player then return false end
          if player.skip_play or #player.hand == 0 then return false end
          local t = nil
          for _, q in ipairs(foes(player, room)) do
            if #q.hand > 0 then t = q break end
          end
          if not t then return false end
          room:log("%s 发动【双刃】，与 %s 拼点", player.name, t.name)
          if not room:pindian(player, t) then
            room:log("%s 拼点失败，跳过出牌阶段", player.name)
            return true -- 截断：跳过出牌阶段
          end
          local slash = phantomCard("slash")
          slash.no_distance_limit = true
          room:log("%s 拼点获胜，视为对 %s 使用一张【杀】", player.name, t.name)
          room:useCard(player, slash, t)
          return false
        end, { zh = "双刃" }),
    },
  },
  {
    name = "田丰", key = "tianfeng", max_hp = 3, kingdom = "qun",
    skills = {
      -- 死谏：失去最后一张手牌时，可弃置一名其他角色的一张牌
      TriggerSkill.create("死谏", TriggerEvent.CardsMoveOneTime,
        function(_, room, player, data)
          if not data or data.player ~= player then return false end
          if data.from_place ~= "hand" or not data.last_handcard then return false end
          local t = nil
          for _, q in ipairs(room:otherAlivePlayers(player)) do
            if #q.hand > 0 then t = q break end
          end
          if not t then return false end
          local c = t.hand[1]
          t:takeCard(c)
          table.insert(room.discardPile, c)
          room:log("%s 发动【死谏】，弃置 %s 的一张手牌", player.name, t.name)
          return false
        end, { zh = "死谏",
          can_trigger = function(_s, room, player, data)
            return data and data.player == player and data.from_place == "hand"
            and data.last_handcard == true
          end }),
      -- 随势（锁定技）：队友濒死时你摸一张牌；队友死亡时你失去 1 点体力
      -- 注：原版按国战「势力结盟」判定，这里用身份局的 allies() 近似。
      TriggerSkill.create("随势", TriggerEvent.Dying,
        function(_, room, player, data)
          if not data or data.player == player then return false end
          for _, q in ipairs(allies(player, room)) do
            if q == data.player then
              room:log("%s 的【随势】生效，摸一张牌", player.name)
              room:drawCards(player, 1)
              return false
            end
          end
          return false
        end, { zh = "随势",
          can_trigger = function(_s, room, player, data)
            return data and data.player ~= nil and data.player ~= player
          end }),
      TriggerSkill.create("随势·殉", TriggerEvent.Death,
        function(_, room, player, data)
          if not data or data.player == player then return false end
          for _, q in ipairs(allies(player, room)) do
            if q == data.player then
              room:log("%s 的【随势】生效，失去 1 点体力", player.name)
              room:loseHp(player, 1)
              return false
            end
          end
          return false
        end, { zh = "随势" }),
    },
  },
  {
    name = "潘凤", key = "panfeng", max_hp = 4, kingdom = "qun",
    skills = {
      -- 狂斧：你用【杀】造成伤害后，可获得目标装备区的一张牌（无空槽则弃置之）
      TriggerSkill.create("狂斧", TriggerEvent.Damage,
        function(_, room, player, data)
          if not data or data.from ~= player or not data.to or not data.card then return false end
          if not isSlashName(data.card.name) then return false end
          local t = data.to
          local card, slot = firstEquipOf(t)
          if not card then return false end
          t.equips[slot] = nil
          if not player.equips[slot] then
            local old = player:equipCard(card, slot)
            if old then table.insert(room.discardPile, old) end
            room:log("%s 发动【狂斧】，将 %s 的【%s】收归己用",
              player.name, t.name, card:zhName())
          else
            table.insert(room.discardPile, card)
            room:log("%s 发动【狂斧】，弃置 %s 的【%s】",
              player.name, t.name, card:zhName())
          end
          return false
        end, { zh = "狂斧",
          can_trigger = function(_s, room, player, data)
            return data and data.from == player and data.to ~= nil
            and data.card ~= nil and isSlashName(data.card.name)
          end }),
    },
  },
  {
    -- 邹氏的两个技能都是国战专属（明置/暗置武将），标准身份局无对应概念。
    -- 先注册进名册保证 60 将齐全，技能待 Phase B 的国战机制再实现。
    name = "邹氏", key = "zoushi", max_hp = 3, kingdom = "qun", female = true,
    hegemony_only = true,
    skills = {},
  },
}

-- 汇总所有已实现的武将
function Generals.all()
  local out = {}
  for _, g in ipairs(Generals.SHU) do table.insert(out, g) end
  for _, g in ipairs(Generals.WEI) do table.insert(out, g) end
  for _, g in ipairs(Generals.WU) do table.insert(out, g) end
  for _, g in ipairs(Generals.QUN) do table.insert(out, g) end
  return out
end

-- 按中文名查武将（联机客户端只拿到武将名时，用它本地还原技能表）
function Generals.byName(name)
  for _, g in ipairs(Generals.all()) do
    if g.name == name then return g end
  end
  return nil
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
