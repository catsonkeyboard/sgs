-- 基础 AI：杀/闪/桃的最优简单策略
-- 阶段 A1 起可替换为原版 lua/ai/smart-ai.lua（经 sgs 兼容层）
local AI = {}

local function firstOpponent(p, room)
  for _, q in ipairs(room.players) do
    if q ~= p and q.alive then return q end
  end
  return nil
end

function AI.makeAI()
  return function(req, room)
    local p = req.player

    if req.type == "askForUseCard" then
      -- 有杀且本回合未用 → 杀对手
      if not p.slash_used then
        local target = firstOpponent(p, room)
        if target then
          for _, c in ipairs(p.hand) do
            if c.name == "slash" then return { card = c, target = target } end
          end
        end
      end
      -- 掉血且有桃 → 吃桃
      if p.hp < p.max_hp then
        for _, c in ipairs(p.hand) do
          if c.name == "peach" then return { card = c, target = p } end
        end
      end
      return nil -- 结束出牌阶段

    elseif req.type == "askForCard" then
      -- 被杀出闪、濒死出桃
      for _, c in ipairs(p.hand) do
        if c.name == req.card_name then return c end
      end
      return nil

    elseif req.type == "askForDiscard" then
      -- 弃牌优先级：先弃闪，再弃杀，最后弃桃
      local order = { dodge = 1, slash = 2, peach = 3 }
      local sorted = {}
      for _, c in ipairs(p.hand) do table.insert(sorted, c) end
      table.sort(sorted, function(a, b)
        return (order[a.name] or 0) < (order[b.name] or 0)
      end)
      local discarded = {}
      for i = 1, math.min(req.n, #sorted) do
        table.insert(discarded, sorted[i])
      end
      return discarded
    end

    return nil
  end
end

return AI
