-- 标准包：牌堆 + 武将 + 技能
--
-- 牌堆配比参考标准版实体牌（杀 30 / 闪 15 / 桃 8 等），花色点数用确定性 LCG 生成，
-- 保证同 seed 可复现。A1 阶段已覆盖：基本牌、全部常用锦囊、延时锦囊、装备。
local Card = require "src.core.card"
local Cards = require "src.core.cards"
local skillmod = require "src.core.skill"
local TriggerSkill = skillmod.TriggerSkill
local TriggerEvent = skillmod.TriggerEvent

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

function Standard.makeRng(seed)
  return makeRng(seed)
end

-- ===== 牌堆 =====

-- 标准牌堆配比：{牌名, 张数}
local DECK_SPEC = {
  -- 基本牌
  { "slash", 24 }, { "fire_slash", 3 }, { "thunder_slash", 3 },
  { "dodge", 15 }, { "peach", 8 }, { "analeptic", 4 },
  -- 锦囊
  { "duel", 3 }, { "snatch", 5 }, { "dismantlement", 6 },
  { "ex_nihilo", 4 }, { "savage_assault", 3 }, { "archery_attack", 1 },
  { "god_salvation", 1 }, { "amazing_grace", 2 }, { "collateral", 2 },
  { "fire_attack", 3 }, { "iron_chain", 4 }, { "nullification", 3 },
  -- 延时锦囊
  { "indulgence", 3 }, { "supply_shortage", 2 }, { "lightning", 1 },
  -- 武器
  { "crossbow", 2 }, { "qinggang_sword", 1 }, { "ice_sword", 1 },
  { "spear", 1 }, { "kylin_bow", 1 }, { "axe", 1 },
  -- 防具
  { "eight_diagram", 2 }, { "renwang_shield", 1 }, { "silver_lion", 1 },
  { "vine", 1 },
  -- 马
  { "offensive_horse", 3 }, { "defensive_horse", 3 },
}

function Standard.deckSize()
  local n = 0
  for _, spec in ipairs(DECK_SPEC) do n = n + spec[2] end
  return n
end

-- 洗好的完整标准牌堆（ctype 由 cards.lua 的定义决定）
function Standard.buildDrawPile(seed)
  local rng = makeRng(seed)
  local cards, id = {}, 0
  local suits = { Card.Suit.Spade, Card.Suit.Heart, Card.Suit.Club, Card.Suit.Diamond }
  for _, spec in ipairs(DECK_SPEC) do
    local name, count = spec[1], spec[2]
    local def = Cards.get(name)
    assert(def, "未知卡牌定义: " .. name)
    for _ = 1, count do
      id = id + 1
      table.insert(cards, Card.create(id, name, suits[rng(4)], rng(13), def.ctype))
    end
  end
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

-- 迷你牌堆：仅杀/闪/桃，用于回归测试与快速对局
function Standard.buildMiniPile(seed)
  local rng = makeRng(seed)
  local cards, id = {}, 0
  local suits = { Card.Suit.Spade, Card.Suit.Heart, Card.Suit.Club, Card.Suit.Diamond }
  for _, spec in ipairs({ { "slash", 15 }, { "dodge", 10 }, { "peach", 4 } }) do
    for _ = 1, spec[2] do
      id = id + 1
      table.insert(cards, Card.create(id, spec[1], suits[rng(4)], rng(13), Card.Type.Basic))
    end
  end
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

-- ===== 武将 =====
-- 武将技能全部在 core/generals.lua（标准包 60 将）与 diy/ 扩展里，
-- 这里不再内联重复定义（曾经内联过张飞/曹操/司马懿/华佗，与 generals.lua 重名
-- 且会互相覆盖，已删除）。

-- 只保留两个占位将；真正的武将全部来自 core/generals.lua 与 DIY 扩展
local GENERALS = {
  { name = "白板武将", max_hp = 4, kingdom = "qun", skills = {} },
  { name = "剑阁武将", max_hp = 4, kingdom = "qun", skills = {} },
}

Standard.PLACEHOLDERS = { ["白板武将"] = true, ["剑阁武将"] = true }

function Standard.setup(engine)
  for _, g in ipairs(GENERALS) do
    engine:registerGeneral(g)
  end
  -- 标准包 60 将（蜀/魏/吴/群，core/generals.lua）
  local Generals = require "src.core.generals"
  for _, g in ipairs(Generals.all()) do
    engine:registerGeneral(g)
  end
end

-- 给玩家随机分配一个武将（不含白板/剑阁占位将）
-- 注意：从 engine.generals 取，而不是上面那张小表——否则新增武将（含 DIY 扩展）
-- 永远不会出现在随机局里。
function Standard.randomGeneral(engine, rng)
  local pool = {}
  for name, g in pairs(engine.generals or {}) do
    if not Standard.PLACEHOLDERS[name] then table.insert(pool, g) end
  end
  if #pool == 0 then return engine:getGeneral("白板武将") end
  table.sort(pool, function(a, b) return a.name < b.name end) -- 保证可复现
  local idx = (rng or math.random)(#pool)
  return pool[idx]
end

return Standard
