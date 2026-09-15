-- 标准版 108 张的**固定**花色点数对照表
--
-- 来源：《三国杀基础版武将与卡牌全表》第 8 节「完整牌堆花色点数对照表」。
-- 之前 Standard.buildDrawPile 用 LCG 随机分配花色与点数，导致：
--   - 每种花色不保证 27 张
--   - 文档总结的分布规律（红桃产桃、方块产闪、黑桃梅花产杀与进攻锦囊）全部消失
--   - 所有依赖花色的技能（洛神/铁骑/刚烈/国色/急救/武圣/雷击/改判）的
--     概率期望与真实牌堆不一致
-- 这里把真实配比固化下来，只保留「洗序」的随机性（同 seed 可复现）。
--
-- 格式：{ 花色, 点数, 内部牌名 }  点数 A=1 J=11 Q=12 K=13
local Card = require "src.core.card"

local S = Card.Suit.Spade
local H = Card.Suit.Heart
local C = Card.Suit.Club
local D = Card.Suit.Diamond

local DeckSpec = {}

DeckSpec.STANDARD = {
  -- ==================== ♠ 黑桃 27 张 ====================
  { S, 1, "duel" }, { S, 1, "lightning" },
  { S, 2, "double_sword" }, { S, 2, "eight_diagram" }, { S, 2, "ice_sword" }, -- EX
  { S, 3, "dismantlement" }, { S, 3, "snatch" },
  { S, 4, "dismantlement" }, { S, 4, "snatch" },
  { S, 5, "blade" }, { S, 5, "jueying" },
  { S, 6, "indulgence" }, { S, 6, "qinggang_sword" },
  { S, 7, "slash" }, { S, 7, "savage_assault" },
  { S, 8, "slash" }, { S, 8, "slash" },
  { S, 9, "slash" }, { S, 9, "slash" },
  { S, 10, "slash" }, { S, 10, "slash" },
  { S, 11, "snatch" }, { S, 11, "nullification" },
  { S, 12, "dismantlement" }, { S, 12, "spear" },
  { S, 13, "savage_assault" }, { S, 13, "dayuan" },

  -- ==================== ♥ 红桃 27 张 ====================
  { H, 1, "god_salvation" }, { H, 1, "archery_attack" },
  { H, 2, "dodge" }, { H, 2, "dodge" },
  { H, 3, "peach" }, { H, 3, "amazing_grace" },
  { H, 4, "peach" }, { H, 4, "amazing_grace" },
  { H, 5, "kylin_bow" }, { H, 5, "chitu" },
  { H, 6, "peach" }, { H, 6, "indulgence" },
  { H, 7, "peach" }, { H, 7, "ex_nihilo" },
  { H, 8, "peach" }, { H, 8, "ex_nihilo" },
  { H, 9, "peach" }, { H, 9, "ex_nihilo" },
  { H, 10, "slash" }, { H, 10, "slash" },
  { H, 11, "slash" }, { H, 11, "ex_nihilo" },
  { H, 12, "peach" }, { H, 12, "dismantlement" }, { H, 12, "lightning" }, -- EX
  { H, 13, "dodge" }, { H, 13, "zhuahuangfeidian" },

  -- ==================== ♣ 梅花 27 张 ====================
  { C, 1, "duel" }, { C, 1, "crossbow" },
  { C, 2, "slash" }, { C, 2, "eight_diagram" }, { C, 2, "renwang_shield" }, -- EX
  { C, 3, "slash" }, { C, 3, "dismantlement" },
  { C, 4, "slash" }, { C, 4, "dismantlement" },
  { C, 5, "slash" }, { C, 5, "dilu" },
  { C, 6, "slash" }, { C, 6, "indulgence" },
  { C, 7, "slash" }, { C, 7, "savage_assault" },
  { C, 8, "slash" }, { C, 8, "slash" },
  { C, 9, "slash" }, { C, 9, "slash" },
  { C, 10, "slash" }, { C, 10, "slash" },
  { C, 11, "slash" }, { C, 11, "slash" },
  { C, 12, "collateral" }, { C, 12, "nullification" },
  { C, 13, "collateral" }, { C, 13, "nullification" },

  -- ==================== ♦ 方块 27 张 ====================
  { D, 1, "crossbow" }, { D, 1, "duel" },
  { D, 2, "dodge" }, { D, 2, "dodge" },
  { D, 3, "dodge" }, { D, 3, "snatch" },
  { D, 4, "dodge" }, { D, 4, "snatch" },
  { D, 5, "dodge" }, { D, 5, "axe" },
  { D, 6, "slash" }, { D, 6, "dodge" },
  { D, 7, "slash" }, { D, 7, "dodge" },
  { D, 8, "slash" }, { D, 8, "dodge" },
  { D, 9, "slash" }, { D, 9, "dodge" },
  { D, 10, "slash" }, { D, 10, "dodge" },
  { D, 11, "dodge" }, { D, 11, "dodge" },
  { D, 12, "peach" }, { D, 12, "halberd" }, { D, 12, "nullification" }, -- EX
  { D, 13, "slash" }, { D, 13, "zixing" },
}

-- 牌名 -> 文档标注的张数，用于校验表本身没有写错
DeckSpec.EXPECTED = {
  slash = 30, dodge = 15, peach = 8,
  duel = 3, dismantlement = 6, snatch = 5, nullification = 4,
  ex_nihilo = 4, indulgence = 3, savage_assault = 3, collateral = 2,
  amazing_grace = 2, lightning = 2, god_salvation = 1, archery_attack = 1,
  crossbow = 2, eight_diagram = 2,
  double_sword = 1, ice_sword = 1, renwang_shield = 1, qinggang_sword = 1,
  blade = 1, spear = 1, axe = 1, halberd = 1, kylin_bow = 1,
  jueying = 1, zhuahuangfeidian = 1, dilu = 1,
  dayuan = 1, chitu = 1, zixing = 1,
}

-- 统计某张表里的牌名张数（自检用）
function DeckSpec.countByName(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    out[row[3]] = (out[row[3]] or 0) + 1
  end
  return out
end

-- 自检：张数与每种花色 27 张都必须对得上
function DeckSpec.verify(rows)
  rows = rows or DeckSpec.STANDARD
  local errs = {}
  local byName = DeckSpec.countByName(rows)
  for name, want in pairs(DeckSpec.EXPECTED) do
    if (byName[name] or 0) ~= want then
      table.insert(errs, string.format("%s: %d ~= %d", name, byName[name] or 0, want))
    end
  end
  local bySuit = {}
  for _, row in ipairs(rows) do bySuit[row[1]] = (bySuit[row[1]] or 0) + 1 end
  for _, s in ipairs({ S, H, C, D }) do
    if (bySuit[s] or 0) ~= 27 then
      table.insert(errs, string.format("花色 %s: %d ~= 27", tostring(s), bySuit[s] or 0))
    end
  end
  return #errs == 0, errs
end

return DeckSpec
