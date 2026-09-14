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

-- 牌堆预设：
--   "standard" 文档标准版 108 张，**花色点数固定**（core/deck_spec.lua），只洗序随机
--   "extended" 标准版 + 军争篇混堆，花色点数随机（对齐标准版之前的旧行为）
Standard.PRESET = "standard"

-- 扩展（军争混堆）牌堆配比：{牌名, 张数}
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
  -- 武器（标准版 9 件：连弩 2 + 其余各 1）
  { "crossbow", 2 }, { "qinggang_sword", 1 }, { "ice_sword", 1 },
  { "double_sword", 1 }, { "blade", 1 }, { "spear", 1 },
  { "axe", 1 }, { "halberd", 1 }, { "kylin_bow", 1 },
  -- 防具
  { "eight_diagram", 2 }, { "renwang_shield", 1 }, { "silver_lion", 1 },
  { "vine", 1 },
  -- 马
  { "offensive_horse", 3 }, { "defensive_horse", 3 },
}

local DeckSpec = require "src.core.deck_spec"

function Standard.deckSize(preset)
  if (preset or Standard.PRESET) == "standard" then
    return #DeckSpec.STANDARD
  end
  local n = 0
  for _, spec in ipairs(DECK_SPEC) do n = n + spec[2] end
  return n
end

-- 标准版 108 张：花色点数固定，仅顺序随机（同 seed 可复现）
function Standard.buildStandardPile(seed)
  local rng = makeRng(seed)
  local cards = {}
  for i, row in ipairs(DeckSpec.STANDARD) do
    local suit, number, name = row[1], row[2], row[3]
    local def = Cards.get(name)
    assert(def, "未知卡牌定义: " .. name)
    table.insert(cards, Card.create(i, name, suit, number, def.ctype))
  end
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

-- 洗好的完整牌堆（ctype 由 cards.lua 的定义决定）
function Standard.buildDrawPile(seed, preset)
  if (preset or Standard.PRESET) == "standard" then
    return Standard.buildStandardPile(seed)
  end
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

-- 给 n 个座位分配**互不重复**的武将。
-- 以前是按固定名单取模分配（座位1永远张飞、座位5又回到张飞），
-- 于是每局武将都一样、座位之间还会重复。
function Standard.pickGenerals(engine, rng, n)
  local pool = {}
  for name, g in pairs(engine.generals or {}) do
    if not Standard.PLACEHOLDERS[name] then table.insert(pool, g) end
  end
  table.sort(pool, function(a, b) return a.name < b.name end) -- 保证可复现
  if #pool == 0 then
    local one = engine:getGeneral("白板武将")
    local out = {}
    for _ = 1, n do table.insert(out, one) end
    return out
  end
  -- Fisher-Yates，取前 n 个
  local f = rng or math.random
  for i = #pool, 2, -1 do
    local j = f(i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local out = {}
  for i = 1, n do table.insert(out, pool[((i - 1) % #pool) + 1]) end
  return out
end

return Standard
