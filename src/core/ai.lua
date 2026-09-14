-- 基础 AI：覆盖全部请求类型与常用卡牌
-- 策略偏保守但不会死锁；阶段 A1 后可替换为原版 lua/ai/smart-ai.lua（经 sgs 兼容层）
local Cards = require "src.core.cards"
local Card = require "src.core.card"

local AI = {}

local function opponentsOf(p, room)
  local out = {}
  for _, q in ipairs(room.players) do
    if q ~= p and q.alive then table.insert(out, q) end
  end
  return out
end

-- 第一个在攻击范围内的敌人
local function targetInRange(p, room)
  local range = p:attackRange()
  for _, q in ipairs(opponentsOf(p, room)) do
    if room:distance(p, q) <= range then return q end
  end
  return nil
end

local function findByName(p, name)
  for _, c in ipairs(p.hand) do
    if c.name == name then return c end
  end
  return nil
end

-- 出牌阶段的优先级：装备 > 纯收益 > 干扰 > 输出
local PLAY_PRIORITY = {
  ex_nihilo = 10, god_salvation = 8,
  crossbow = 9, qinggang_sword = 9, ice_sword = 9, spear = 9, kylin_bow = 9, axe = 9,
  eight_diagram = 9, renwang_shield = 9, silver_lion = 8, vine = 7,
  offensive_horse = 9, defensive_horse = 9,
  dismantlement = 7, snatch = 7, duel = 6, collateral = 5,
  fire_attack = 6, indulgence = 6, supply_shortage = 6, lightning = 2,
  iron_chain = 3, slash = 5, fire_slash = 6, thunder_slash = 6,
  peach = 4, analeptic = 3,
}

function AI.makeAI()
  return function(req, room)
    local p = req.player

    -------------------------------------------------- 出牌阶段
    if req.type == "askForUseCard" then
      -- 濒危先回血
      if p.hp < p.max_hp then
        local peach = findByName(p, "peach")
        if peach then return { card = peach, target = p } end
      end

      local best, best_score, best_target = nil, -1, nil
      for _, c in ipairs(p.hand) do
        local score = PLAY_PRIORITY[c.name]
        if score then
          local def = Cards.get(c.name)
          local ok, target = true, nil

          if def and def.ctype == Card.Type.Equip then
            target = p
          elseif def and Cards.isDelayed(c.name) then
            if c.name == "lightning" then
              target = p
              ok = p:hasDelayed("lightning") == nil
            else
              local foe = nil
              for _, q in ipairs(opponentsOf(p, room)) do
                if q:hasDelayed(c.name) == nil
                  and not (def.distance and room:distance(p, q) > def.distance) then
                  foe = q
                  break
                end
              end
              target, ok = foe, foe ~= nil
            end
          elseif def and def.target == "enemy" then
            local foe = nil
            for _, q in ipairs(opponentsOf(p, room)) do
              if not (def.distance and room:distance(p, q) > def.distance) then
                foe = q
                break
              end
            end
            target, ok = foe, foe ~= nil
          elseif c.name == "slash" or c.name == "fire_slash" or c.name == "thunder_slash" then
            if p.slash_count > 0 and not room:allowsUnlimitedSlash(p) then
              ok = false
            else
              target = targetInRange(p, room)
              ok = target ~= nil
            end
          elseif c.name == "nullification" or c.name == "dodge" then
            ok = false -- 不能主动使用
          else
            target = p
          end

          if ok and score > best_score then
            best, best_score, best_target = c, score, target
          end
        end
      end

      if best then return { card = best, target = best_target } end
      return nil -- 结束出牌阶段

    -------------------------------------------------- 打出指定牌
    elseif req.type == "askForCard" then
      local wanted = req.card_name

      -- 【无懈可击】只在「别人的牌作用在自己身上」时才用，避免无谓消耗
      if wanted == "nullification" then
        local target = req.ask_target
        local source = req.ask_from
        if not target or target ~= p then return nil end
        if source == p then return nil end
        return findByName(p, "nullification")
      end

      local card = findByName(p, wanted)
      -- 濒死无桃时可用酒
      if wanted == "peach" and not card and p.hp <= 0 then
        card = findByName(p, "analeptic")
      end
      return card

    -------------------------------------------------- 弃牌
    elseif req.type == "askForDiscard" then
      local order = { dodge = 1, slash = 2, fire_slash = 2, thunder_slash = 2,
        peach = 3, analeptic = 3, nullification = 4 }
      local sorted = {}
      for _, c in ipairs(p.hand) do table.insert(sorted, c) end
      table.sort(sorted, function(a, b)
        return (order[a.name] or 2.5) < (order[b.name] or 2.5)
      end)
      local out = {}
      for i = 1, math.min(req.n, #sorted) do table.insert(out, sorted[i]) end
      return out

    -------------------------------------------------- 五谷丰登：选一张
    elseif req.type == "askForChooseCard" then
      local list = req.cards or {}
      if #list == 0 then return nil end
      local prefer = { peach = 5, analeptic = 4, nullification = 4,
        ex_nihilo = 4, slash = 3, dodge = 3 }
      local best, best_score = list[1], -1
      for _, c in ipairs(list) do
        local s = prefer[c.name] or 1
        local def = Cards.get(c.name)
        if def and def.ctype == Card.Type.Equip then s = 4 end
        if s > best_score then best, best_score = c, s end
      end
      return best

    -------------------------------------------------- 过河拆桥：替对手挑一张弃掉
    elseif req.type == "askForDiscardFrom" then
      local t = req.target
      if not t or #t.hand == 0 then return nil end
      local key = { peach = 3, analeptic = 3, nullification = 3, slash = 2, dodge = 1 }
      local best, best_score = t.hand[1], -1
      for _, c in ipairs(t.hand) do
        local s = key[c.name] or 1
        if s > best_score then best, best_score = c, s end
      end
      return best
    end

    return nil
  end
end

return AI
