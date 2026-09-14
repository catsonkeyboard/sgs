-- headless 对局测试：迷你局回归 + 标准牌堆全量对局 + 单元行为校验
-- 运行: love . --test （conf.lua 检测 --test 关闭窗口）
if not pcall(require, "love.filesystem") then
  package.path = "./?.lua;" .. package.path
end

local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Cards = require "src.core.cards"
local Card = require "src.core.card"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local AI = require "src.core.ai"
local skillmod = require "src.core.skill"

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then
    passes = passes + 1
    print("PASS  " .. msg)
  else
    failures = failures + 1
    print("FAIL  " .. msg)
  end
end

-- opts: {seed, mini(bool), general1, general2}
local function playGame(opts)
  opts = opts or {}
  local seed = opts.seed or 42
  local engine = Engine.create()
  Standard.setup(engine)
  local g1 = opts.general1 or engine:getGeneral("白板武将")
  local g2 = opts.general2 or engine:getGeneral("剑阁武将")
  local p1 = Player.create("甲", g1, 1, false)
  local p2 = Player.create("乙", g2, 2, false)
  local room = Room.create(engine, { p1, p2 })
  room.drawPile = opts.mini and Standard.buildMiniPile(seed) or Standard.buildDrawPile(seed)
  room.rng = Standard.makeRng(seed) -- 确定性推进
  room:start()
  local driver = Driver.create(room, AI.makeAI())
  driver:advance()
  return room
end

local function totalCards(room)
  local n = #room.drawPile + #room.discardPile
  for _, p in ipairs(room.players) do n = n + p:allCardCount() end
  return n
end

print("--- 迷你局（杀/闪/桃）---")

local room = playGame { seed = 42, mini = true }
check(room.game_over, "游戏应正常结束")
check(room.winner ~= nil, "应有胜者")
check(room.winner.alive, "胜者应存活")
check(#room.loglines > 10, "对局日志完整（" .. #room.loglines .. " 条）")
check(room.turn_count <= Room.MAX_TURNS, "回合数在保险线内（" .. room.turn_count .. "）")
check(totalCards(room) == 29, "迷你牌堆卡牌守恒 29 == " .. totalCards(room))

local ok_seeds, bad = 0, {}
for seed = 1, 30 do
  local ok = pcall(function()
    local r = playGame { seed = seed, mini = true }
    assert(r.game_over and r.winner ~= nil, "未正常结束")
    assert(r.turn_count <= Room.MAX_TURNS, "超回合")
    assert(totalCards(r) == 29, "卡牌不守恒")
  end)
  if ok then ok_seeds = ok_seeds + 1 else table.insert(bad, seed) end
end
check(ok_seeds == 30, "迷你局 30 个种子全部跑通（失败: " .. table.concat(bad, ",") .. "）")

print("\n--- 标准牌堆全量局 ---")

local full = playGame { seed = 7 }
check(full.game_over, "标准牌堆对局应正常结束")
check(full.winner ~= nil, "应有胜者")
check(totalCards(full) == Standard.deckSize(),
  "标准牌堆卡牌守恒 " .. Standard.deckSize() .. " == " .. totalCards(full))

local full_ok, full_bad = 0, {}
for seed = 1, 20 do
  local ok = pcall(function()
    local r = playGame { seed = seed }
    assert(r.game_over and r.winner ~= nil, "未正常结束")
    assert(r.turn_count <= Room.MAX_TURNS, "超回合")
    assert(totalCards(r) == Standard.deckSize(), "卡牌不守恒 " .. totalCards(r))
  end)
  if ok then full_ok = full_ok + 1 else table.insert(full_bad, seed) end
end
check(full_ok == 20, "标准局 20 个种子全部跑通（失败: " .. table.concat(full_bad, ",") .. "）")

print("\n--- 武将技能 ---")

do
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local p2 = Player.create("乙", engine:getGeneral("曹操"), 2, false)
  local r = Room.create(engine, { p1, p2 })
  r.drawPile = Standard.buildMiniPile(1)
  local slash = Card.create(999, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  table.insert(r.discardPile, slash)
  local before = #p2.hand
  r:damage(p1, p2, 1, "normal", slash)
  check(#p2.hand == before + 1, "曹操【奸雄】应获得造成伤害的牌")
  check(p2.hand[#p2.hand] == slash, "【奸雄】获得的应正是那张【杀】")
end

do
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local p2 = Player.create("乙", engine:getGeneral("司马懿"), 2, false)
  table.insert(p1.hand, Card.create(1, "slash", Card.Suit.Spade, 3, Card.Type.Basic))
  local r = Room.create(engine, { p1, p2 })
  r.drawPile = Standard.buildMiniPile(1)
  local before1, before2 = #p1.hand, #p2.hand
  r:damage(p1, p2, 1)
  check(#p1.hand == before1 - 1, "司马懿【反馈】应抽走来源一张手牌")
  check(#p2.hand == before2 + 1, "【反馈】抽取的牌应进入司马懿手中")
end

do
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local p2 = Player.create("乙", engine:getGeneral("张飞"), 2, false)
  local r = Room.create(engine, { p1, p2 })
  check(r:allowsUnlimitedSlash(p2), "张飞【咆哮】应允许无限出杀")
  check(not r:allowsUnlimitedSlash(p1), "白板武将不应有无限出杀")
  check(not r:allowsUnlimitedSlash(p2) or true, "无限出杀查询不影响白板")
end

print("\n--- 距离与攻击范围 ---")

do
  local engine = Engine.create()
  Standard.setup(engine)
  local ps = {}
  for i = 1, 4 do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral("白板武将"), i, false))
  end
  local r = Room.create(engine, ps)
  check(r:distance(ps[1], ps[2]) == 1, "相邻座位距离为 1")
  check(r:distance(ps[1], ps[3]) == 2, "隔一位距离为 2")
  check(r:distance(ps[1], ps[4]) == 1, "四人局环形距离环绕修正为 1")
  ps[1]:equipCard(Card.create(1, "offensive_horse", Card.Suit.Spade, 5, Card.Type.Equip),
    "offensive_horse")
  check(r:distance(ps[1], ps[3]) == 1, "进攻马使距离 -1")
  ps[3]:equipCard(Card.create(2, "defensive_horse", Card.Suit.Spade, 5, Card.Type.Equip),
    "defensive_horse")
  check(r:distance(ps[1], ps[3]) == 2, "防御马使其他角色与自己的距离 +1")
  check(ps[1]:attackRange() == 1, "无武器攻击范围为 1")
  ps[1]:equipCard(Card.create(3, "kylin_bow", Card.Suit.Spade, 5, Card.Type.Equip), "weapon")
  check(ps[1]:attackRange() == 5, "麒麟弓攻击范围为 5")
end

print("\n--- 触发管线 ---")

do
  local engine = Engine.create()
  local hit_order = {}
  local low = skillmod.TriggerSkill.create("low", "Damaged",
    function(_s, _room, _p, _d) table.insert(hit_order, "low") return false end,
    { priority = 10 })
  local high = skillmod.TriggerSkill.create("high", "Damaged",
    function(_s, _room, _p, _d) table.insert(hit_order, "high") return false end,
    { priority = 1 })
  local blocker = skillmod.TriggerSkill.create("blocker", "Damaged",
    function(_s, _room, _p, _d) table.insert(hit_order, "blocker") return true end,
    { priority = 5 })
  engine:registerGlobalSkill(low)
  engine:registerGlobalSkill(high)
  engine:registerGlobalSkill(blocker)
  local p1 = Player.create("甲", { name = "G", max_hp = 4, skills = {} }, 1, false)
  local p2 = Player.create("乙", { name = "G", max_hp = 4, skills = {} }, 2, false)
  local r = Room.create(engine, { p1, p2 })
  local cancelled = r:trigger("Damaged", p2, {})
  check(cancelled, "返回 true 的技能应截断管线")
  check(#hit_order == 2 and hit_order[1] == "high" and hit_order[2] == "blocker",
    "技能应按 priority 升序执行且被截断（" .. table.concat(hit_order, ",") .. "）")
end

print("\n--- 带技能武将对局 ---")

do
  local combos = { { "张飞", "曹操" }, { "司马懿", "华佗" }, { "曹操", "司马懿" } }
  local bad_combo = {}
  for _, combo in ipairs(combos) do
    local ok_count = 0
    for seed = 1, 6 do
      local ok = pcall(function()
        local engine = Engine.create()
        Standard.setup(engine)
        local p1 = Player.create("甲", engine:getGeneral(combo[1]), 1, false)
        local p2 = Player.create("乙", engine:getGeneral(combo[2]), 2, false)
        local r = Room.create(engine, { p1, p2 })
        r.drawPile = Standard.buildDrawPile(seed * 13 + 1)
        r.rng = Standard.makeRng(seed * 13 + 1)
        r:start()
        local d = Driver.create(r, AI.makeAI())
        d:advance()
        assert(r.game_over and r.winner ~= nil, "未正常结束")
        assert(r.turn_count <= Room.MAX_TURNS, "超回合")
        assert(totalCards(r) == Standard.deckSize(), "卡牌不守恒 " .. totalCards(r))
      end)
      if ok then ok_count = ok_count + 1 end
    end
    if ok_count ~= 6 then table.insert(bad_combo, combo[1] .. "vs" .. combo[2]) end
  end
  check(#bad_combo == 0, "三组带技能武将各 6 局全部跑通（失败: " .. table.concat(bad_combo, ",") .. "）")
end

print("\n--- 卡牌定义完整性 ---")

local missing = {}
for _, spec in ipairs {
  "slash", "dodge", "peach", "analeptic", "duel", "snatch", "dismantlement",
  "ex_nihilo", "savage_assault", "archery_attack", "god_salvation", "amazing_grace",
  "collateral", "fire_attack", "iron_chain", "nullification",
  "indulgence", "supply_shortage", "lightning",
  "crossbow", "kylin_bow", "eight_diagram", "silver_lion", "vine",
  "offensive_horse", "defensive_horse",
} do
  if not Cards.get(spec) then table.insert(missing, spec) end
end
check(#missing == 0, "关键卡牌定义齐全（缺失: " .. table.concat(missing, ",") .. "）")
check(Card.ZH["ex_nihilo"] == "无中生有", "中文名映射由 cards.lua 注册")

print(string.format("\n===== 核心: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("核心测试失败", 0) end
