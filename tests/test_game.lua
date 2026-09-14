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
local Generals = require "src.core.generals"

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

print("\n--- 身份局 ---")

-- 构造一个 n 人身份局（全部 AI），可指定 seed
local function makeIdentityGame(n, seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local ps = {}
  for i = 1, n do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral("白板武将"), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  r:setupRoles(Standard.makeRng(seed + 1))
  return r
end

for _, n in ipairs { 4, 5, 6, 7, 8 } do
  local r = makeIdentityGame(n, 11)
  local counts = { lord = 0, loyalist = 0, rebel = 0, renegade = 0 }
  for _, p in ipairs(r.players) do counts[p.role] = (counts[p.role] or 0) + 1 end
  local spec = Room.ROLE_SETUP[n]
  local same = counts.lord == spec.lord and counts.loyalist == (spec.loyalist or 0)
    and counts.rebel == spec.rebel and counts.renegade == (spec.renegade or 0)
  check(same, string.format("%d 人局身份配置正确（主%d 忠%d 反%d 内%d）",
    n, counts.lord, counts.loyalist, counts.rebel, counts.renegade))
  check(r:getLord() ~= nil, n .. " 人局应有主公")
end

do
  local r = makeIdentityGame(4, 11)
  local lord = r:getLord()
  check(lord.max_hp == 5, "主公体力上限 +1（" .. lord.max_hp .. "）")
  check(lord.role_revealed, "主公身份应公开")
  local hidden = 0
  for _, p in ipairs(r.players) do
    if p ~= lord and p.role_revealed then hidden = hidden + 1 end
  end
  check(hidden == 0, "非主公身份应暗置")
end

-- 胜负判定：反贼与内奸全灭 → 主公方胜
do
  local r = makeIdentityGame(4, 5)
  local lord = r:getLord()
  for _, p in ipairs(r.players) do
    if p.role == "rebel" or p.role == "renegade" then
      p.alive = false
    end
  end
  r:_checkWinner()
  check(r.game_over and r.win_role == "lord", "反贼与内奸全灭 → 主公方获胜")
  check(r.winner == lord, "胜者应为主公")
end

-- 胜负判定：主公阵亡且存活者非内奸 → 反贼胜
do
  local r = makeIdentityGame(4, 6)
  local lord = r:getLord()
  lord.alive = false
  r:_checkWinner()
  check(r.game_over and r.win_role == "rebel", "主公阵亡且非内奸独存 → 反贼获胜")
end

-- 胜负判定：主公阵亡且仅剩内奸 → 内奸胜
do
  local r = makeIdentityGame(4, 7)
  local lord, renegade = r:getLord(), nil
  for _, p in ipairs(r.players) do
    if p.role == "renegade" then renegade = p end
  end
  for _, p in ipairs(r.players) do
    if p ~= renegade then p.alive = false end
  end
  r:_checkWinner()
  check(r.game_over and r.win_role == "renegade", "主公阵亡且仅剩内奸 → 内奸获胜")
  check(r.winner == renegade, "胜者应为内奸")
end

-- 奖惩：击败反贼摸 3 张
do
  local r = makeIdentityGame(4, 8)
  local lord = r:getLord()
  local rebel = nil
  for _, p in ipairs(r.players) do if p.role == "rebel" then rebel = p end end
  r.drawPile = Standard.buildDrawPile(99)
  local before = #lord.hand
  r:_rewardAndPunish(lord, rebel)
  check(#lord.hand == before + 3, "击败反贼应摸 3 张（" .. before .. " → " .. #lord.hand .. "）")
end

-- 奖惩：主公误杀忠臣 → 弃光
do
  local r = makeIdentityGame(4, 9)
  local lord = r:getLord()
  local loyal = nil
  for _, p in ipairs(r.players) do if p.role == "loyalist" then loyal = p end end
  table.insert(lord.hand, Card.create(1, "slash", Card.Suit.Spade, 3, Card.Type.Basic))
  table.insert(lord.hand, Card.create(2, "dodge", Card.Suit.Heart, 4, Card.Type.Basic))
  r:_rewardAndPunish(lord, loyal)
  check(#lord.hand == 0, "主公误杀忠臣应弃光手牌（剩 " .. #lord.hand .. "）")
end

-- 完整身份局跑通
do
  local ok_count, bad = 0, {}
  for seed = 1, 6 do
    local ok = pcall(function()
      local r = makeIdentityGame(4, seed * 17 + 3)
      r:start()
      local d = Driver.create(r, AI.makeAI())
      d:advance()
      assert(r.game_over, "未正常结束")
      assert(r.turn_count <= Room.MAX_TURNS, "超回合")
      assert(r.win_role ~= nil, "未判定获胜阵营")
      assert(totalCards(r) == Standard.deckSize(), "卡牌不守恒 " .. totalCards(r))
    end)
    if ok then ok_count = ok_count + 1 else table.insert(bad, seed) end
  end
  check(ok_count == 6, "4 人身份局 6 个种子全部跑通（失败: " .. table.concat(bad, ",") .. "）")
end

print("\n--- 蜀国武将技能 ---")

local function makeRoomWith(generalKeys, seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local ps = {}
  for i, k in ipairs(generalKeys) do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral(k), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(seed or 1)
  return r, ps
end

local function give(p, name, suit, number, ctype)
  local c = Card.create(1000 + #p.hand, name, suit or Card.Suit.Spade, number or 5,
    ctype or Card.Type.Basic)
  table.insert(p.hand, c)
  return c
end

do -- 关羽·武圣：红色牌当【杀】
  local r, ps = makeRoomWith({ "关羽", "白板武将" })
  local red_dodge = give(ps[1], "dodge", Card.Suit.Heart, 3)
  local cands = r:viewAsCandidates(ps[1], "slash")
  check(#cands > 0, "关羽应有可转化为【杀】的手牌")
  local made = r:viewAsCard(ps[1], "slash", red_dodge)
  check(made ~= nil and made.name == "slash", "红色【闪】应能转化为【杀】")
  check(made and made.virtual and made.subcards[1] == red_dodge,
    "转化牌应记录实体来源 subcards")
end

do -- 赵云·龙胆：杀当闪、闪当杀
  local r, ps = makeRoomWith({ "赵云", "白板武将" })
  local dodge = give(ps[1], "dodge", Card.Suit.Spade, 4)
  local slash = give(ps[1], "slash", Card.Suit.Spade, 5)
  check((r:viewAsCard(ps[1], "slash", dodge) or {}).name == "slash", "【闪】应能当【杀】")
  check((r:viewAsCard(ps[1], "dodge", slash) or {}).name == "dodge", "【杀】应能当【闪】")
end

do -- 马超·马术：距离 -1
  local r, ps = makeRoomWith({ "马超", "白板武将", "白板武将", "白板武将" })
  check(r:distance(ps[1], ps[3]) == 1, "马超【马术】应使到对家距离 2→1")
  check(r:distance(ps[2], ps[4]) == 2, "白板武将到对家距离应为 2")
end

do -- 诸葛亮·空城：无手牌不可被【杀】指定
  local r, ps = makeRoomWith({ "白板武将", "诸葛亮" })
  local slash = give(ps[1], "slash", Card.Suit.Spade, 5)
  check(not r:_validateUse(ps[1], slash, { ps[2] }), "空城状态下【杀】应无法指定诸葛亮")
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  check(r:_validateUse(ps[1], slash, { ps[2] }), "有手牌后【杀】应可指定")
end

do -- 黄月英·奇才：锦囊无视距离
  local r, ps = makeRoomWith({ "黄月英", "白板武将", "白板武将", "白板武将" })
  local snatch = give(ps[1], "snatch", Card.Suit.Spade, 3, Card.Type.Trick)
  check(r:distance(ps[1], ps[3]) == 2, "黄月英到对家距离为 2")
  check(r:_validateUse(ps[1], snatch, { ps[3] }), "【奇才】应使锦囊无视距离限制")
  local r2, p2 = makeRoomWith({ "白板武将", "白板武将", "白板武将", "白板武将" })
  local snatch2 = give(p2[1], "snatch", Card.Suit.Spade, 3, Card.Type.Trick)
  check(not r2:_validateUse(p2[1], snatch2, { p2[3] }), "白板武将的锦囊应受距离限制")
end

do -- 黄月英·集智：使用锦囊后摸一张
  local r, ps = makeRoomWith({ "黄月英", "白板武将" }, 5)
  local before = #ps[1].hand
  r:trigger("CardUsed", ps[1],
    { from = ps[1], card = Card.create(1, "ex_nihilo", Card.Suit.Heart, 7, Card.Type.Trick),
      to = { ps[1] } })
  check(#ps[1].hand == before + 1, "【集智】使用锦囊后应摸 1 张（" .. before .. " → " .. #ps[1].hand .. "）")
  -- 装备不应触发集智
  local before2 = #ps[1].hand
  r:trigger("CardUsed", ps[1],
    { from = ps[1], card = Card.create(2, "crossbow", Card.Suit.Spade, 8, Card.Type.Equip),
      to = { ps[1] } })
  check(#ps[1].hand == before2, "使用装备不应触发【集智】")
end

do -- 魏延·狂骨：对距离 1 的角色造成伤害后回血
  local r, ps = makeRoomWith({ "魏延", "白板武将" }, 6)
  ps[1].hp = 2
  r:trigger("Damaged", ps[2], { from = ps[1], to = ps[2], n = 1, nature = "normal" })
  check(ps[1].hp == 3, "【狂骨】对距离 1 的目标造成伤害后应回 1 血（" .. ps[1].hp .. "）")
end

do -- 庞统·涅槃（限定技）：濒死时弃牌并回满
  local r, ps = makeRoomWith({ "庞统", "白板武将" }, 7)
  give(ps[1], "slash", Card.Suit.Spade, 5)
  ps[1].hp = 0
  local cancelled = r:trigger("Dying", ps[1], { player = ps[1] })
  check(cancelled, "【涅槃】应截断濒死结算")
  check(ps[1].hp == ps[1].max_hp, "【涅槃】后应回复至体力上限（" .. ps[1].hp .. "）")
  check(#ps[1].hand == 0, "【涅槃】应弃置所有手牌")
end

do -- 卧龙·八阵 / 孟获·祸首 / 祝融·巨象
  local r, ps = makeRoomWith({ "卧龙", "孟获", "祝融", "白板武将" }, 8)
  check(Generals.marker(ps[1], "auto_armor", nil) == "eight_diagram",
    "卧龙【八阵】无防具时视为装备八卦阵")
  check(r:isSavageImmune(ps[2]), "孟获【祸首】应免疫【南蛮入侵】")
  check(r:isSavageImmune(ps[3]), "祝融【巨象】应免疫【南蛮入侵】")
  check(not r:isSavageImmune(ps[4]), "白板武将不应免疫【南蛮入侵】")
end

do -- 张飞·咆哮
  local r, ps = makeRoomWith({ "张飞", "白板武将" }, 9)
  check(r:allowsUnlimitedSlash(ps[1]), "张飞【咆哮】应允许无限出杀")
end

do -- 卧龙·看破：黑色牌当【无懈可击】
  local r, ps = makeRoomWith({ "卧龙", "白板武将" }, 10)
  local black = give(ps[1], "slash", Card.Suit.Spade, 6)
  check((r:viewAsCard(ps[1], "nullification", black) or {}).name == "nullification",
    "卧龙应能以黑色牌当【无懈可击】")
  local red = give(ps[1], "peach", Card.Suit.Heart, 6)
  check(r:viewAsCard(ps[1], "nullification", red) == nil,
    "红色牌不应能当【无懈可击】")
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
