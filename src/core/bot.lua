-- 基础 BOT：覆盖全部请求类型与常用卡牌
-- 这是**规则驱动**的脚本对手，不是机器学习/LLM。
-- 策略偏保守但不会死锁；后续会接入真正由 LLM 驱动的 AI，届时两者并存：
--   BOT（本文件）  —— 规则启发式，无学习、无推理、无搜索，行为可复现
--   AI（规划中）   —— 大语言模型驱动，只在关键抉择上调用
local Cards = require "src.core.cards"
local Card = require "src.core.card"

local Bot = {}

-- 候选目标：身份局下按阵营敌我排序，非身份局就是「除自己外的存活者」
local function opponentsOf(p, room)
  local out = {}
  for _, q in ipairs(room.players) do
    if q ~= p and q.alive then table.insert(out, q) end
  end
  if not p.role or not room.identity_mode then return out end

  local want
  local role = p.role
  if role == "lord" or role == "loyalist" then
    want = { "rebel", "renegade" }
  elseif role == "rebel" then
    want = { "lord", "loyalist" }
  elseif role == "renegade" then
    -- 内奸：场上人多时先削反贼，残局谁都打
    if #room:alivePlayers() > 2 then want = { "rebel" } else want = { "lord", "loyalist", "rebel" } end
  else
    return out
  end

  local ordered, seen = {}, {}
  for _, r in ipairs(want) do
    for _, q in ipairs(out) do
      if q.role == r and not seen[q] then seen[q] = true table.insert(ordered, q) end
    end
  end
  for _, q in ipairs(out) do
    if not seen[q] then table.insert(ordered, q) end
  end
  return ordered
end

-- 攻击范围内的敌人选谁打：按「体力*2 + 手牌数」取最小。
--   - 体力是主项：残血优先（集火）。原来取「第一个」，伤害被平均分摊，
--     谁也杀不死，遇到【名士】这类减伤技能必然打成僵局。
--   - 手牌数是次项：残局双方都在囤牌时，手牌少的那个才【闪】得出来，
--     不打他就会陷入「每回合出一张杀、对方出一张闪」的永久拉锯。
local function targetInRange(p, room)
  local range = room:attackRangeOf(p)
  local best, best_score = nil, nil
  for _, q in ipairs(opponentsOf(p, room)) do
    if room:distance(p, q) <= range then
      local score = q.hp * 2 + #q.hand
      if best_score == nil or score < best_score then
        best, best_score = q, score
      end
    end
  end
  return best
end

-- ok 为额外的可用判定（如鸡肋过滤）
local function findByName(p, name, ok)
  for _, c in ipairs(p.hand) do
    if c.name == name and (not ok or ok(p, c)) then return c end
  end
  return nil
end

-- 身份局下 p 是否视 q 为敌
local function isEnemy(p, q, room)
  if not p.role or not room.identity_mode then return true end -- 非身份局人人是敌
  local r = p.role
  if r == "lord" or r == "loyalist" then
    return q.role == "rebel" or q.role == "renegade"
  elseif r == "rebel" then
    return q.role == "lord" or q.role == "loyalist"
  elseif r == "renegade" then
    return #room:alivePlayers() <= 2 or q.role == "rebel"
  end
  return true
end

-- 出牌阶段的优先级：装备 > 纯收益 > AOE > 干扰 > 输出
-- 注意：AOE（南蛮/万箭）与群体治疗（桃园）需要按敌我分布动态判断，
-- 不能只看固定优先级，否则 8 人局会因无人输出而长时间僵持。
local PLAY_PRIORITY = {
  ex_nihilo = 10,
  savage_assault = 7, archery_attack = 7, amazing_grace = 5,
  god_salvation = 8,
  crossbow = 9, qinggang_sword = 9, ice_sword = 9, spear = 9, kylin_bow = 9, axe = 9,
  double_sword = 9, blade = 9, halberd = 9,
  eight_diagram = 9, renwang_shield = 9, silver_lion = 8, vine = 7,
  offensive_horse = 9, defensive_horse = 9,
  dismantlement = 7, snatch = 7, duel = 6, collateral = 5,
  fire_attack = 6, indulgence = 6, supply_shortage = 6, lightning = 2,
  iron_chain = 3, slash = 5, fire_slash = 6, thunder_slash = 6,
  peach = 4, analeptic = 3,
}

-- 出牌阶段会尝试用转化技「变」出来的牌名（按性价比排序，先试收益高的）。
-- 只有出现在这里的牌名才会被 BOT 主动转化使用；纯响应（闪/无懈可击）走
-- askForCard 分支里的 viewAsCandidates，不需要登记。
local CONVERT_TARGETS = {
  "dismantlement", "indulgence", "supply_shortage", "await_exhausted",
  "slash", "fire_attack", "snatch", "duel",
}

-- 该牌是否可用（鸡肋封禁的牌 BOT 也不能拿出来）
local function usable(p, c)
  return not p:isJilei(c)
end

function Bot.make()
  return function(req, room)
    local p = req.player

    -------------------------------------------------- 出牌阶段
    if req.type == "askForUseCard" then
      -- 濒危先回血
      if p.hp < p.max_hp then
        local peach = findByName(p, "peach")
        if peach then return { card = peach, target = p } end
      end

      -- 候选池：手牌本身在前，转化技产出的虚拟牌在后（同分时优先出真牌）
      local pool = {}
      for _, c in ipairs(p.hand) do
        table.insert(pool, { card = c, cname = c.name })
      end
      -- 转化技主动出牌：【奇袭】黑牌当过河拆桥、【国色】方块当乐不思蜀、
      -- 【武圣】红牌当杀 等。没有这段的话这些技能在 BOT 手里等于废的。
      for _, want in ipairs(CONVERT_TARGETS) do
        local cands = room:viewAsCandidates(p, want)
        if #cands > 0 then
          local args = { cands[1].card }
          if cands[1].card2 then args[2] = cands[1].card2 end -- 双牌转化技
          local made = cands[1].skill:view_as(args)
          if made then
            table.insert(pool, { card = made, cname = want, skill = cands[1].skill })
          end
        end
      end

      local best, best_score, best_target = nil, -1, nil
      for _, item in ipairs(pool) do
        local c, cname = item.card, item.cname
        local score = PLAY_PRIORITY[cname]
        if score then
          local def = Cards.get(cname)
          local ok, target = true, nil

          -- 技能牌（原版 SkillCard）：没有卡牌定义，目标由 filter/feasible 决定。
          -- 这里做近似：target_fixed 对自己，否则打第一个敌人。
          if not def and c.skill_card then
            if c.skill_card.target_fixed then
              target = p
            else
              for _, q in ipairs(opponentsOf(p, room)) do
                target = q
                break
              end
              ok = target ~= nil
            end
          elseif def and def.ctype == Card.Type.Equip then
            target = p
          elseif def and Cards.isDelayed(cname) then
            if cname == "lightning" then
              target = p
              ok = p:hasDelayed("lightning") == nil
            else
              local foe = nil
              for _, q in ipairs(opponentsOf(p, room)) do
                if q:hasDelayed(cname) == nil
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
          elseif def and def.target == "all_other" then
            -- AOE：只在不会误伤自己人时使用
            target = p
            local foes, allies = 0, 0
            for _, q in ipairs(opponentsOf(p, room)) do
              if isEnemy(p, q, room) then foes = foes + 1 else allies = allies + 1 end
            end
            ok = (foes > 0 and foes >= allies)
          elseif def and def.target == "all" then
            -- 群体收益：桃园结义不能资敌
            target = p
            if cname == "god_salvation" then
              local wounded_foes = 0
              for _, q in ipairs(room:alivePlayers()) do
                if q.hp < q.max_hp and isEnemy(p, q, room) then
                  wounded_foes = wounded_foes + 1
                end
              end
              ok = (p.hp < p.max_hp) and (wounded_foes == 0)
            else
              ok = true
            end
          elseif cname == "slash" or cname == "fire_slash" or cname == "thunder_slash" then
            if p.slash_count > 0 and not room:allowsUnlimitedSlash(p) then
              ok = false
            else
              target = targetInRange(p, room)
              ok = target ~= nil
            end
          elseif cname == "nullification" or cname == "dodge" then
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

      -- 主公技求助（【护驾】/【激将】）：敌人不提供
      if req.lord_request and isEnemy(p, req.lord_request, room) then return nil end

      -- 救援他人濒死：只救自己人；【酒】只能对自己使用，这里只出【桃】
      -- （转化出的【桃】走下面的 viewAsCandidates，如【急救】红色牌当桃救人）
      if wanted == "peach" and req.dying and req.dying ~= p then
        if isEnemy(p, req.dying, room) then return nil end
        return findByName(p, "peach", usable)
      end

      local card = findByName(p, wanted, usable)
      -- 濒死无桃时可用酒
      if wanted == "peach" and not card and p.hp <= 0 then
        card = findByName(p, "analeptic", usable)
      end
      -- 没有原牌时用转化技顶上（【看破】黑色牌当无懈可击、【龙胆】杀当闪 等）
      if not card then
        local made = nil
        local cands = room:viewAsCandidates(p, wanted)
        for _, item in ipairs(cands) do
          if usable(p, item.card) then
            made = item.skill:view_as({ item.card })
            if made then
              room:log("%s 以【%s】转化出一张【%s】", p.name, item.skill.name, made:zhName())
              break
            end
          end
        end
        if made then card = made end
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

return Bot
