-- 标准包卡牌定义：锦囊与装备
--
-- 基本牌（杀/闪/桃/酒）的结算与武器防具的被动交互耦合较深，放在 room.lua；
-- 这里集中定义「牌的属性 + 锦囊效果 + 装备被动」，与原版 src/package/ 对应。
--
-- 每个 def 的字段：
--   zh        中文名
--   ctype     Card.Type.Basic / Trick / Equip
--   equip     "weapon"/"armor"/"offensive_horse"/"defensive_horse"
--   range     武器攻击范围
--   target    "none"/"self"/"enemy"/"all"/"all_other"
--   delayed   是否为延时锦囊（进判定区）
--   distance  使用时对目标的距离上限
--   nullifiable 是否可被【无懈可击】抵消
--   effect(room, use)  use = {from=, card=, to={...}}
--   judge(room, player, card)  延时锦囊判定结果 -> true 表示生效
local Card = require "src.core.card"

local Cards = { defs = {} }
local T = Card.Type

function Cards.define(name, def)
  def.name = name
  def.ctype = def.ctype or T.Trick
  Cards.defs[name] = def
  Card.ZH[name] = def.zh or name
  return def
end

function Cards.get(name)
  return Cards.defs[name]
end

function Cards.isTrick(name)
  local d = Cards.defs[name]
  return d ~= nil and d.ctype == T.Trick
end

function Cards.isEquip(name)
  local d = Cards.defs[name]
  return d ~= nil and d.ctype == T.Equip
end

function Cards.isDelayed(name)
  local d = Cards.defs[name]
  return d ~= nil and d.delayed == true
end

-- 通用：从目标手里随机取一张牌（用于过河拆桥等）
local function randomCardOf(p)
  if #p.hand == 0 then return nil end
  return p.hand[math.random(#p.hand)]
end

-- ==================== 基本牌 ====================
-- 结算逻辑在 Room:_useBasic（与武器/防具/伤害管线耦合较深），
-- 这里只登记元数据，供牌堆构建与统一查询使用。

Cards.define("slash", { zh = "杀", ctype = T.Basic, target = "enemy", range = 1 })
Cards.define("fire_slash", { zh = "火杀", ctype = T.Basic, target = "enemy", range = 1 })
Cards.define("thunder_slash", { zh = "雷杀", ctype = T.Basic, target = "enemy", range = 1 })
Cards.define("dodge", { zh = "闪", ctype = T.Basic, target = "none" })
Cards.define("peach", { zh = "桃", ctype = T.Basic, target = "self" })
Cards.define("analeptic", { zh = "酒", ctype = T.Basic, target = "self" })

-- ==================== 锦囊 ====================

Cards.define("duel", {
  zh = "决斗", target = "enemy", nullifiable = true,
  effect = function(room, use)
    local a, b = use.from, use.to[1]
    if not (a and b) then return end
    room:log("%s 对 %s 使用【决斗】", a.name, b.name)
    local attacker, defender = b, a -- 由目标先出杀
    while true do
      local slash = room:askForCard(defender, "slash",
        string.format("决斗：%s 需打出一张【杀】，否则受到 1 点伤害", defender.name))
      if slash and defender:takeCard(slash) then
        room:log("%s 打出【杀】", defender.name)
        room:throwCard(defender, slash)
        attacker, defender = defender, attacker
      else
        room:log("%s 无法打出【杀】，受到 1 点伤害", defender.name)
        room:damage(attacker, defender, 1)
        return
      end
    end
  end,
})

Cards.define("snatch", {
  zh = "顺手牵羊", target = "enemy", distance = 1, nullifiable = true,
  effect = function(room, use)
    local from, to = use.from, use.to[1]
    if not to then return end
    if #to.hand == 0 then room:log("%s 没有手牌可顺", to.name) return end
    local card = randomCardOf(to)
    to:takeCard(card)
    table.insert(from.hand, card)
    room:log("%s 顺走 %s 的一张手牌", from.name, to.name)
  end,
})

Cards.define("dismantlement", {
  zh = "过河拆桥", target = "enemy", nullifiable = true,
  effect = function(room, use)
    local from, to = use.from, use.to[1]
    if not to then return end
    room:log("%s 对 %s 使用【过河拆桥】", from.name, to.name)
    room:askForDiscardFrom(from, to, 1)
  end,
})

Cards.define("ex_nihilo", {
  zh = "无中生有", target = "self", nullifiable = true,
  effect = function(room, use)
    room:log("%s 使用【无中生有】，摸两张牌", use.from.name)
    room:drawCards(use.from, 2)
  end,
})

Cards.define("savage_assault", {
  zh = "南蛮入侵", target = "all_other", nullifiable = true,
  effect = function(room, use)
    local from = use.from
    room:log("%s 使用【南蛮入侵】", from.name)
    for _, p in ipairs(use.to) do
      if p.alive then
        if room:isSavageImmune(p) then
          room:log("%s 免疫【南蛮入侵】（藤甲 / 祸首 / 巨象）", p.name)
        else
          local slash = room:askForCard(p, "slash", "南蛮入侵：打出【杀】，否则受到 1 点伤害")
          if slash and p:takeCard(slash) then
            room:throwCard(p, slash)
          else
            room:damage(from, p, 1)
          end
        end
      end
    end
  end,
})

Cards.define("archery_attack", {
  zh = "万箭齐发", target = "all_other", nullifiable = true,
  effect = function(room, use)
    local from = use.from
    room:log("%s 使用【万箭齐发】", from.name)
    for _, p in ipairs(use.to) do
      if p.alive then
        if p:hasEquip("vine") then
          room:log("%s 的【藤甲】使【万箭齐发】无效", p.name)
        else
          local dodge = room:askForCard(p, "dodge", "万箭齐发：打出【闪】，否则受到 1 点伤害")
          if dodge and p:takeCard(dodge) then
            room:throwCard(p, dodge)
          else
            room:damage(from, p, 1)
          end
        end
      end
    end
  end,
})

Cards.define("god_salvation", {
  zh = "桃园结义", target = "all", nullifiable = true,
  effect = function(room, use)
    room:log("%s 使用【桃园结义】", use.from.name)
    for _, p in ipairs(use.to) do
      if p.alive then room:heal(p, 1) end
    end
  end,
})

Cards.define("amazing_grace", {
  zh = "五谷丰登", target = "all", nullifiable = true,
  effect = function(room, use)
    local players = room:alivePlayers()
    room:log("%s 使用【五谷丰登】", use.from.name)
    local revealed = {}
    for _ = 1, #players do
      if #room.drawPile == 0 then break end
      table.insert(revealed, table.remove(room.drawPile))
    end
    if #revealed == 0 then return end
    for _, p in ipairs(players) do
      if #revealed == 0 then break end
      local picked = room:askForChooseCard(p, revealed, "五谷丰登：选择一张牌收入手牌")
      if not picked then picked = revealed[1] end -- 未选择则取第一张，避免丢牌
      local idx = 1
      for i, c in ipairs(revealed) do if c == picked then idx = i break end end
      table.remove(revealed, idx)
      table.insert(p.hand, picked)
      room:log("%s 获得一张牌", p.name)
    end
    for _, c in ipairs(revealed) do table.insert(room.discardPile, c) end
  end,
})

Cards.define("collateral", {
  zh = "借刀杀人", target = "enemy", nullifiable = true,
  effect = function(room, use)
    local from, to = use.from, use.to[1]
    if not to then return end
    room:log("%s 对 %s 使用【借刀杀人】", from.name, to.name)
    local weapon = to.equips and to.equips.weapon
    if weapon then
      local victim = nil
      for _, q in ipairs(room:alivePlayers()) do
        if q ~= to and room:distance(to, q) <= (weapon.range or 1) then victim = q break end
      end
      if victim then
        local slash = room:askForCard(to, "slash",
          string.format("借刀杀人：对 %s 使用【杀】，否则武器归 %s", victim.name, from.name))
        if slash and to:takeCard(slash) then
          room:throwCard(to, slash)
          local dodge = room:askForCard(victim, "dodge", "请打出【闪】")
          if dodge and victim:takeCard(dodge) then
            room:throwCard(victim, dodge)
          else
            room:damage(to, victim, 1)
          end
          return
        end
      end
    end
    if weapon then
      to.equips.weapon = nil
      table.insert(from.hand, weapon)
      room:log("%s 获得 %s 的武器", from.name, to.name)
    end
  end,
})

Cards.define("fire_attack", {
  zh = "火攻", target = "enemy", nullifiable = true,
  effect = function(room, use)
    local from, to = use.from, use.to[1]
    if not (to and #to.hand > 0) then return end
    room:log("%s 对 %s 使用【火攻】", from.name, to.name)
    local shown = to.hand[math.random(#to.hand)]
    room:log("%s 展示 %s", to.name, shown:displayName())
    local same = nil
    for _, c in ipairs(from.hand) do
      if c.suit == shown.suit then same = c break end
    end
    if same then
      from:takeCard(same)
      room:throwCard(from, same)
      room:log("%s 弃置同花色牌，%s 受到 1 点火焰伤害", from.name, to.name)
      room:damage(from, to, 1, "fire")
    else
      room:log("%s 无法弃置同花色牌，火攻失败", from.name)
    end
  end,
})

Cards.define("iron_chain", {
  zh = "铁索连环", target = "enemy", nullifiable = true,
  effect = function(room, use)
    local to = use.to[1]
    if not to then return end
    to.chained = not to.chained
    room:log("%s %s铁索连环状态", to.name, to.chained and "进入" or "解除")
    room:trigger("ChainStateChanged", to, { player = to })
  end,
})

Cards.define("nullification", {
  zh = "无懈可击", target = "none", nullifiable = false,
  effect = function() end, -- 仅作响应牌使用，主动使用无效果
})

-- ==================== 延时锦囊 ====================

Cards.define("indulgence", {
  zh = "乐不思蜀", target = "enemy", delayed = true, nullifiable = true,
  judge = function(room, player, card)
    local hit = card.suit ~= Card.Suit.Heart
    room:log("%s 的【乐不思蜀】判定：%s %s", player.name, card:suitString(),
      hit and "非红桃，跳过出牌阶段" or "红桃，无效")
    return hit
  end,
  on_judged = function(room, player, hit)
    if hit then player.skip_play = true end
  end,
})

Cards.define("supply_shortage", {
  zh = "兵粮寸断", target = "enemy", delayed = true, distance = 1, nullifiable = true,
  judge = function(room, player, card)
    local hit = card.suit ~= Card.Suit.Club
    room:log("%s 的【兵粮寸断】判定：%s %s", player.name, card:suitString(),
      hit and "非梅花，跳过摸牌阶段" or "梅花，无效")
    return hit
  end,
  on_judged = function(room, player, hit)
    if hit then player.skip_draw = true end
  end,
})

Cards.define("lightning", {
  zh = "闪电", target = "self", delayed = true, nullifiable = true,
  judge = function(room, player, card)
    local hit = card.suit == Card.Suit.Spade and card.number >= 2 and card.number <= 9
    room:log("%s 的【闪电】判定：%s%d %s", player.name, card:suitString(), card.number,
      hit and "黑桃 2-9，命中！" or "未命中，传给下家")
    return hit
  end,
  -- 未命中时由 Room 传给下家，而不是进弃牌堆
  pass_on_miss = true,
  on_judged = function(room, player, hit)
    if hit then room:damage(nil, player, 3, "thunder") end
  end,
})

-- ==================== 装备 ====================

Cards.define("crossbow", {
  zh = "诸葛连弩", ctype = T.Equip, equip = "weapon", range = 1,
  desc = "出牌阶段使用【杀】的次数不限",
})
Cards.define("qinggang_sword", {
  zh = "青釭剑", ctype = T.Equip, equip = "weapon", range = 2,
  desc = "无视目标防具",
})
Cards.define("ice_sword", {
  zh = "寒冰剑", ctype = T.Equip, equip = "weapon", range = 2,
  desc = "【杀】造成伤害时，改为弃置目标两张牌",
})
Cards.define("spear", {
  zh = "丈八蛇矛", ctype = T.Equip, equip = "weapon", range = 3,
  desc = "可将两张手牌当【杀】使用或打出",
})
Cards.define("kylin_bow", {
  zh = "麒麟弓", ctype = T.Equip, equip = "weapon", range = 5,
  desc = "【杀】命中后，弃置目标一匹马",
})
Cards.define("axe", {
  zh = "贯石斧", ctype = T.Equip, equip = "weapon", range = 3,
  desc = "【杀】被闪避时，可弃两张牌强制命中",
})

Cards.define("eight_diagram", {
  zh = "八卦阵", ctype = T.Equip, equip = "armor",
  desc = "需要打出【闪】时，可判定：红色生效",
})
Cards.define("renwang_shield", {
  zh = "仁王盾", ctype = T.Equip, equip = "armor",
  desc = "黑色【杀】对你无效",
})
Cards.define("silver_lion", {
  zh = "白银狮子", ctype = T.Equip, equip = "armor",
  desc = "受到的伤害大于 1 时改为 1；失去时回复 1 点体力",
})
Cards.define("vine", {
  zh = "藤甲", ctype = T.Equip, equip = "armor",
  desc = "火焰伤害 +1；【南蛮入侵】【万箭齐发】与普通【杀】无效",
})

Cards.define("offensive_horse", {
  zh = "进攻马", ctype = T.Equip, equip = "offensive_horse", range = 0,
  desc = "你与其他角色的距离 -1",
})
Cards.define("defensive_horse", {
  zh = "防御马", ctype = T.Equip, equip = "defensive_horse", range = 0,
  desc = "其他角色与你的距离 +1",
})

-- ==================== 技能牌 ====================
-- 由转化技（ViewAsSkill）产生的虚拟牌，不参与牌堆构造，仅用于结算分派。

Cards.define("rende", {
  zh = "仁德", ctype = T.Basic, target = "other",
  effect = function(room, use)
    local to = use.to and use.to[1]
    if not to then return end
    local n = 0
    for _, sc in ipairs(use.card.subcards or {}) do
      table.insert(to.hand, sc)
      n = n + 1
    end
    use.card.sub_consumed = true -- 实体牌已交给目标，不再进弃牌堆
    room:log("%s 将 %d 张牌交给 %s", use.from.name, n, to.name)
  end,
})

Cards.define("shushen", { zh = "淑慎", ctype = T.Basic, target = "other" })

return Cards
