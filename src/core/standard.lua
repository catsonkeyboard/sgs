-- 标准包 v0：白板武将 + 杀/闪/桃迷你牌堆
-- A1 阶段将扩展为完整标准包（锦囊/装备/全武将），并从原版数据迁移。
local Card = require "src.core.card"

local Standard = {}

-- 确定性 LCG（测试可复现）
local function makeRng(seed)
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (s * 16807) % 2147483647
    return (s % n) + 1
  end
end

function Standard.makeRng(seed) return makeRng(seed) end

function Standard.setup(engine)
  engine:registerGeneral { name = "白板武将", max_hp = 4, skills = {} }
  engine:registerGeneral { name = "剑阁武将", max_hp = 4, skills = {} }
end

-- 迷你牌堆：15 杀 / 10 闪 / 4 桃（29 张，1v1 足够）
function Standard.buildDrawPile(seed)
  local rng = makeRng(seed)
  local cards, id = {}, 0
  local specs = { { "slash", 15 }, { "dodge", 10 }, { "peach", 4 } }
  for _, spec in ipairs(specs) do
    for _ = 1, spec[2] do
      id = id + 1
      table.insert(cards, Card.create(id, spec[1], rng(4), rng(13)))
    end
  end
  -- Fisher-Yates（同一 rng，保证同 seed 同牌堆）
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

return Standard
