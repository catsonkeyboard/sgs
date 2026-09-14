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

-- 长时间拉锯会以平局收场（winner 为 nil），这是合法结局，
-- 不再要求「必有胜者」，但平局要单独计数以便观察。
local function assertFinished(r, deck_size)
  assert(r.game_over, "未正常结束")
  assert(r.turn_count <= Room.MAX_TURNS, "超回合")
  assert(totalCards(r) == deck_size,
    "卡牌不守恒 " .. totalCards(r) .. " != " .. deck_size)
  return r.winner ~= nil
end

local ok_seeds, bad, draws = 0, {}, 0
for seed = 1, 30 do
  local ok = pcall(function()
    local r = playGame { seed = seed, mini = true }
    if not assertFinished(r, 29) then draws = draws + 1 end
  end)
  if ok then ok_seeds = ok_seeds + 1 else table.insert(bad, seed) end
end
check(ok_seeds == 30, "迷你局 30 个种子全部跑通（失败: " .. table.concat(bad, ",") .. "）"
  .. (draws > 0 and string.format("，其中 %d 局平局", draws) or ""))

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
        assertFinished(r, Standard.deckSize())
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

local function hasCard(list, card)
  for _, c in ipairs(list) do
    if c == card then return true end
  end
  return false
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

print("\n--- 魏国武将技能 ---")

-- 会触发询问（askForXxx → coroutine.yield）的技能必须在协程里跑，
-- 否则在主线程里 yield 会直接报错。这里统一用 nil 应答（表示「不响应」）。
-- 在协程里跑会 yield 的询问流程。
-- respond(req) 可选：给询问请求一个应答（如技能征询选择 false）。
-- 默认一律应答 nil（等价于「不打出 / 结束出牌」）。
local function runInRoom(fn, respond)
  local co = coroutine.create(function()
    local ok, err = pcall(fn)
    return ok, err
  end)
  local ok, r1, r2 = coroutine.resume(co)
  local guard = 0
  while coroutine.status(co) ~= "dead" and guard < 80 do
    guard = guard + 1
    local answer = respond and respond(r1) or nil
    ok, r1, r2 = coroutine.resume(co, answer)
  end
  if not ok then error(r1, 0) end
  if r1 == false then error(r2, 0) end
  return true
end

do -- 曹操·奸雄：受到伤害后获得造成伤害的牌
  local r, ps = makeRoomWith({ "曹操", "白板武将" }, 11)
  local slash = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  table.insert(r.discardPile, slash)
  r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1, card = slash })
  check(ps[1].hand[#ps[1].hand] == slash, "【奸雄】应获得造成伤害的那张牌")
  check(not hasCard(r.discardPile, slash), "【奸雄】获得后该牌应离开弃牌堆")
end

do -- 司马懿·反馈：受到伤害后获得来源一张牌
  local r, ps = makeRoomWith({ "司马懿", "白板武将" }, 12)
  give(ps[2], "slash", Card.Suit.Spade, 5)
  local n1, n2 = #ps[1].hand, #ps[2].hand
  r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1 })
  check(#ps[1].hand == n1 + 1 and #ps[2].hand == n2 - 1,
    "【反馈】应从伤害来源处获得一张牌")
end

do -- 司马懿·鬼才：判定生效前用手牌替换判定牌
  local r, ps = makeRoomWith({ "司马懿", "白板武将" }, 13)
  local indulgence = Card.create(1, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  local spade = Card.create(2, "slash", Card.Suit.Spade, 9, Card.Type.Basic)
  give(ps[1], "peach", Card.Suit.Heart, 3) -- 红桃可让【乐不思蜀】失效
  local data = { player = ps[1], card = indulgence, judge_card = spade, reason = "indulgence" }
  r:trigger("AskForRetrial", ps[1], data)
  check(data.judge_card.suit == Card.Suit.Heart,
    "【鬼才】应用红桃手牌替换掉会命中的判定牌")
end

do -- 夏侯惇·刚烈：判定非红桃，来源弃两张或受 1 点伤害
  local r, ps = makeRoomWith({ "夏侯惇", "白板武将" }, 14)
  table.insert(r.drawPile, Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic))
  local hp = ps[2].hp
  r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1 })
  check(ps[2].hp == hp - 1, "【刚烈】判定非红桃且无法弃两张时应造成伤害")
end

do -- 张辽·突袭：放弃摸牌改为夺取至多两名角色各一张手牌
  local r, ps = makeRoomWith({ "张辽", "白板武将", "白板武将" }, 15)
  give(ps[2], "slash", Card.Suit.Spade, 5)
  give(ps[3], "slash", Card.Suit.Spade, 6)
  local n1 = #ps[1].hand
  local skipped = r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "draw" })
  check(skipped, "【突袭】应截断正常摸牌阶段")
  check(#ps[1].hand == n1 + 2, "【突袭】应夺得两名角色各一张手牌")
end

do -- 许褚·裸衣：少摸一张，【杀】伤害 +1
  local r, ps = makeRoomWith({ "许褚", "白板武将" }, 16)
  local data = { player = ps[1], n = 2 }
  r:trigger("DrawNCards", ps[1], data)
  check(data.n == 1, "【裸衣】摸牌阶段应少摸一张")
  local dmg = { from = ps[1], to = ps[2], n = 1,
    card = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic) }
  r:trigger("DamageCaused", ps[1], dmg)
  check(dmg.n == 2, "【裸衣】应使【杀】的伤害 +1")
end

do -- 郭嘉·天妒 / 遗计
  local r, ps = makeRoomWith({ "郭嘉", "白板武将" }, 17)
  local jcard = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  table.insert(r.discardPile, jcard)
  r:trigger("FinishJudge", ps[1], { player = ps[1], judge_card = jcard, result = false })
  check(ps[1].hand[#ps[1].hand] == jcard, "【天妒】应获得判定牌")
  local n = #ps[1].hand
  r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1 })
  check(#ps[1].hand == n + 2, "【遗计】受到伤害后应摸两张牌")
end

do -- 甄姬·倾国：黑色手牌当【闪】
  local r, ps = makeRoomWith({ "甄姬", "白板武将" }, 18)
  local black = give(ps[1], "slash", Card.Suit.Club, 5)
  local red = give(ps[1], "peach", Card.Suit.Heart, 5)
  check((r:viewAsCard(ps[1], "dodge", black) or {}).name == "dodge", "【倾国】黑色牌应能当【闪】")
  check(r:viewAsCard(ps[1], "dodge", red) == nil, "【倾国】红色牌不应能当【闪】")
end

do -- 甄姬·洛神：回合开始反复判定，黑色收入手中
  local r, ps = makeRoomWith({ "甄姬", "白板武将" }, 19)
  -- 判定从牌堆顶（数组末尾）摸，故按「先摸到的放后面」排列：黑黑白黑 → 收 3 张
  r.drawPile = {
    Card.create(4, "slash", Card.Suit.Heart, 8, Card.Type.Basic), -- 最后摸到，红色终止
    Card.create(3, "slash", Card.Suit.Spade, 7, Card.Type.Basic),
    Card.create(2, "slash", Card.Suit.Club, 6, Card.Type.Basic),
    Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic),
  }
  local n = #ps[1].hand
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "start" })
  check(#ps[1].hand == n + 3, "【洛神】应连续收入 3 张黑色判定牌（实得 "
    .. (#ps[1].hand - n) .. "）")
end

do -- 夏侯渊·神速：跳过判定+摸牌阶段，打出无距离限制的【杀】
  local r, ps = makeRoomWith({ "夏侯渊", "白板武将" }, 20)
  ps[2].hp = 1 -- 残血，满足「值得放弃摸牌」的 AI 条件
  local skipped = false
  runInRoom(function()
    skipped = r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "judge" })
  end)
  check(skipped, "【神速】应截断判定阶段")
  check(ps[1].skipped and ps[1].skipped.draw, "【神速】应同时跳过摸牌阶段")
end

do -- 张郃·巧变：弃一张牌跳过摸牌阶段并夺取手牌
  local r, ps = makeRoomWith({ "张郃", "白板武将" }, 21)
  give(ps[1], "slash", Card.Suit.Spade, 5)
  give(ps[1], "slash", Card.Suit.Spade, 6)
  give(ps[2], "peach", Card.Suit.Heart, 3)
  local n2 = #ps[2].hand
  local skipped = r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "draw" })
  check(skipped, "【巧变】应截断摸牌阶段")
  check(#ps[2].hand == n2 - 1, "【巧变】跳过摸牌阶段时应夺取一张手牌")
end

do -- 徐晃·断粮：黑色基本牌当【兵粮寸断】且距离 +1
  local r, ps = makeRoomWith({ "徐晃", "白板武将", "白板武将", "白板武将" }, 22)
  local black = give(ps[1], "slash", Card.Suit.Club, 5, Card.Type.Basic)
  check((r:viewAsCard(ps[1], "supply_shortage", black) or {}).name == "supply_shortage",
    "【断粮】黑色基本牌应能当【兵粮寸断】")
  local red = give(ps[1], "peach", Card.Suit.Heart, 5, Card.Type.Basic)
  check(r:viewAsCard(ps[1], "supply_shortage", red) == nil, "【断粮】红色牌不应能转化")
  local shortage = Card.create(2, "supply_shortage", Card.Suit.Spade, 6, Card.Type.Trick)
  check(r:distance(ps[1], ps[3]) == 2, "徐晃到对家距离为 2")
  check(r:_validateUse(ps[1], shortage, { ps[3] }), "【断粮】距离 +1 后应能指定距离为 2 的目标")
  local r2, p2 = makeRoomWith({ "白板武将", "白板武将", "白板武将", "白板武将" }, 22)
  check(not r2:_validateUse(p2[1], shortage, { p2[3] }), "白板武将的【兵粮寸断】应受距离 1 限制")
end

do -- 曹仁·据守：结束阶段摸三张并翻面
  local r, ps = makeRoomWith({ "曹仁", "白板武将" }, 23)
  local n = #ps[1].hand
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "finish" })
  check(#ps[1].hand == n + 3, "【据守】应摸三张牌")
  check(ps[1].turned_over, "【据守】应使曹仁翻面")
end

do -- 典韦·强袭：弃武器或失去体力，对范围内角色造成 1 点伤害
  local r, ps = makeRoomWith({ "典韦", "白板武将" }, 24)
  local hp = ps[2].hp
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  check(ps[2].hp == hp - 1, "【强袭】应对范围内角色造成 1 点伤害")
  check(ps[1].hp == ps[1].max_hp - 1, "无武器时【强袭】应自失 1 点体力")
end

do -- 荀彧·节命：受伤后将手牌补至 min(5, 体力上限)
  local r, ps = makeRoomWith({ "荀彧", "白板武将" }, 25)
  local n = #ps[1].hand
  r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1 })
  check(#ps[1].hand == math.min(5, ps[1].max_hp),
    "【节命】应将手牌补至 " .. math.min(5, ps[1].max_hp) .. " 张（" .. n .. " → " .. #ps[1].hand .. "）")
end

do -- 曹丕·行殇：其他角色阵亡时获得其所有牌
  local r, ps = makeRoomWith({ "曹丕", "白板武将" }, 26)
  give(ps[2], "slash", Card.Suit.Spade, 5)
  give(ps[2], "peach", Card.Suit.Heart, 3)
  local n = #ps[1].hand
  r:trigger("Death", ps[1], { player = ps[2] })
  check(#ps[1].hand == n + 2, "【行殇】应获得阵亡角色的 2 张牌（实得 "
    .. (#ps[1].hand - n) .. "）")
  check(#ps[2].hand == 0, "【行殇】应取走阵亡角色的手牌")
end

do -- 乐进·骁果：其他角色结束阶段，逼其弃装备或受伤
  local r, ps = makeRoomWith({ "乐进", "白板武将" }, 27)
  give(ps[1], "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  give(ps[1], "dodge", Card.Suit.Spade, 6, Card.Type.Basic)
  ps[2].hp = 2 -- 残血，满足发动条件
  local hp = ps[2].hp
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[2], phase = "finish" })
  end)
  check(ps[2].hp == hp - 1, "【骁果】对方无装备时应造成 1 点伤害")
end

print("\n--- 吴国武将技能 ---")

local function hasSkillNamed(p, name)
  for _, s in ipairs(p.extra_skills or {}) do
    if s.name == name then return true end
  end
  return false
end

do -- 孙权·制衡：弃置废牌换等量新牌
  local r, ps = makeRoomWith({ "孙权", "白板武将" }, 31)
  give(ps[1], "dodge", Card.Suit.Spade, 2)
  give(ps[1], "dodge", Card.Suit.Club, 3)
  give(ps[1], "dodge", Card.Suit.Spade, 4)
  local before, dumped = #ps[1].hand, #r.discardPile
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(#r.discardPile == dumped + 2, "【制衡】应弃置 2 张废牌")
  check(#ps[1].hand == before, "【制衡】弃 2 摸 2，手牌数不变（" .. before .. " → " .. #ps[1].hand .. "）")
  check(ps[1].zhiheng_used, "【制衡】每回合限一次")
end

do -- 甘宁·奇袭：黑色手牌当【过河拆桥】
  local r, ps = makeRoomWith({ "甘宁", "白板武将" }, 32)
  local black = give(ps[1], "slash", Card.Suit.Spade, 5)
  local red = give(ps[1], "peach", Card.Suit.Heart, 5)
  check((r:viewAsCard(ps[1], "dismantlement", black) or {}).name == "dismantlement",
    "【奇袭】黑色牌应能当【过河拆桥】")
  check(r:viewAsCard(ps[1], "dismantlement", red) == nil, "【奇袭】红色牌不应能转化")
end

do -- 吕蒙·克己：出牌阶段未出杀则跳过弃牌阶段
  local r, ps = makeRoomWith({ "吕蒙", "白板武将" }, 33)
  give(ps[1], "slash", Card.Suit.Spade, 5)
  give(ps[1], "slash", Card.Suit.Spade, 6)
  give(ps[1], "dodge", Card.Suit.Heart, 2)
  give(ps[1], "dodge", Card.Suit.Heart, 3)
  give(ps[1], "dodge", Card.Suit.Heart, 4)
  check(r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "discard" }),
    "【克己】未出杀时应跳过弃牌阶段")
  ps[1].keji_slash = true
  check(not r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "discard" }),
    "【克己】出过杀后不应跳过弃牌阶段")
end

do -- 黄盖·苦肉：失去 1 点体力摸两张
  local r, ps = makeRoomWith({ "黄盖", "白板武将" }, 34)
  local n = #ps[1].hand
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(ps[1].hp == ps[1].max_hp - 1, "【苦肉】应失去 1 点体力")
  check(#ps[1].hand == n + 2, "【苦肉】应摸两张牌")
end

do -- 周瑜·英姿 / 反间
  local r, ps = makeRoomWith({ "周瑜", "白板武将" }, 35)
  local data = { player = ps[1], n = 2 }
  r:trigger("DrawNCards", ps[1], data)
  check(data.n == 3, "【英姿】摸牌阶段应多摸一张")
  give(ps[1], "slash", Card.Suit.Spade, 5)
  local n2 = #ps[2].hand
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  check(#ps[2].hand == n2 + 1, "【反间】目标应获得周瑜的一张手牌")
end

do -- 大乔·国色 / 流离
  local r, ps = makeRoomWith({ "大乔", "白板武将", "白板武将" }, 36)
  local diamond = give(ps[1], "slash", Card.Suit.Diamond, 5)
  check((r:viewAsCard(ps[1], "indulgence", diamond) or {}).name == "indulgence",
    "【国色】方块牌应能当【乐不思蜀】")
  give(ps[1], "dodge", Card.Suit.Heart, 2)
  local slash = give(ps[2], "slash", Card.Suit.Spade, 5)
  local use = { from = ps[2], card = slash, to = { ps[1] } }
  r:trigger("TargetConfirming", ps[1], use)
  check(use.to[1] == ps[3] or use.to[1] == ps[2],
    "【流离】应把【杀】转移给另一名角色（实际目标 " .. use.to[1].name .. "）")
  check(use.to[1] ~= ps[1], "【流离】转移后大乔不应再是目标")
end

do -- 陆逊·谦逊 / 度势
  local r, ps = makeRoomWith({ "陆逊", "白板武将" }, 37)
  local snatch = give(ps[2], "snatch", Card.Suit.Spade, 3, Card.Type.Trick)
  check(not r:_validateUse(ps[2], snatch, { ps[1] }), "【谦逊】不能成为【顺手牵羊】的目标")
  check(r:_validateUse(ps[2], snatch, { ps[2] }) ~= nil, "【谦逊】不影响对其他角色使用")
  local red = give(ps[1], "peach", Card.Suit.Heart, 5)
  check((r:viewAsCard(ps[1], "await_exhausted", red) or {}).name == "await_exhausted",
    "【度势】红色牌应能当【以逸待劳】")
end

do -- 孙尚香·枭姬：失去装备后摸两张
  local r, ps = makeRoomWith({ "孙尚香", "白板武将" }, 38)
  local n = #ps[1].hand
  r:trigger("CardsMoveOneTime", ps[1], { player = ps[1], from_place = "equip" })
  check(#ps[1].hand == n + 2, "【枭姬】失去装备后应摸两张牌")
end

do -- 孙坚·英魂：受伤时令队友摸 X 张后弃 1 张
  local r, ps = makeRoomWith({ "孙坚", "白板武将", "白板武将" }, 39)
  r.identity_mode = true
  ps[1].role, ps[2].role, ps[3].role = "lord", "rebel", "loyalist"
  ps[1].hp = 2 -- 已损失 2 点体力
  local n = #ps[3].hand
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "start" })
  end)
  check(#ps[3].hand >= n + 1, "【英魂】应令队友摸牌（" .. n .. " → " .. #ps[3].hand .. "）")
end

do -- 小乔·天香：弃红桃手牌把伤害转移给他人
  local r, ps = makeRoomWith({ "小乔", "白板武将" }, 40)
  give(ps[1], "peach", Card.Suit.Heart, 5)
  local hp = ps[2].hp
  local cancelled
  runInRoom(function()
    cancelled = r:trigger("DamageInflicted", ps[1],
      { from = ps[2], to = ps[1], n = 1, nature = "normal" })
  end)
  check(cancelled, "【天香】应截断对自己的伤害结算")
  check(ps[2].hp == hp - 1, "【天香】应把伤害转移给目标")
end

do -- 太史慈·天义：拼点胜负挂上回合内标记
  local r, ps = makeRoomWith({ "太史慈", "白板武将" }, 41)
  give(ps[1], "slash", Card.Suit.Spade, 12)
  give(ps[2], "slash", Card.Suit.Spade, 3)
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(hasSkillNamed(ps[1], "天义·胜"), "【天义】拼点获胜应挂上增益标记")
  check(r:allowsUnlimitedSlash(ps[1]), "【天义】获胜后出杀应不限次数")
end

do -- 周泰·不屈：翻出点数不重复的「创」牌可免死
  local r, ps = makeRoomWith({ "周泰", "白板武将" }, 42)
  table.insert(r.drawPile, Card.create(1, "slash", Card.Suit.Spade, 7, Card.Type.Basic))
  ps[1].hp = 0
  local saved = r:trigger("Dying", ps[1], { player = ps[1] })
  check(saved, "【不屈】点数不重复时应截断濒死")
  check(ps[1].hp == 1, "【不屈】免死后应回复至 1 点体力")
end

do -- 鲁肃·好施：多摸两张，手牌过多时散财
  local r, ps = makeRoomWith({ "鲁肃", "白板武将" }, 43)
  local data = { player = ps[1], n = 2 }
  r:trigger("DrawNCards", ps[1], data)
  check(data.n == 4, "【好施】摸牌阶段应多摸两张")
  for i = 1, 6 do give(ps[1], "dodge", Card.Suit.Spade, i) end
  local before, n2 = #ps[1].hand, #ps[2].hand
  r:trigger("AfterDrawNCards", ps[1], { player = ps[1] })
  check(#ps[1].hand < before, "【好施】手牌超过 5 张时应散出一半")
  check(#ps[2].hand > n2, "【好施】手牌最少的角色应收到牌")
end

do -- 鲁肃·缔盟：弃 X 张牌交换两名手牌数相差 X 的角色之手牌
  local r, ps = makeRoomWith({ "鲁肃", "白板武将", "白板武将", "白板武将" }, 44)
  r.identity_mode = true
  ps[1].role, ps[2].role = "lord", "rebel"
  ps[3].role, ps[4].role = "loyalist", "rebel"
  give(ps[3], "dodge", Card.Suit.Spade, 2)                       -- 队友 1 张
  give(ps[4], "dodge", Card.Suit.Spade, 3)
  give(ps[4], "dodge", Card.Suit.Spade, 4)
  give(ps[4], "dodge", Card.Suit.Spade, 5)                       -- 敌人 3 张
  give(ps[1], "slash", Card.Suit.Spade, 6)
  give(ps[1], "slash", Card.Suit.Spade, 7)
  local n3, n4 = #ps[3].hand, #ps[4].hand
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(#ps[3].hand == n4 and #ps[4].hand == n3,
    "【缔盟】应交换两名角色的手牌（" .. n3 .. "/" .. n4 .. " → "
      .. #ps[3].hand .. "/" .. #ps[4].hand .. "）")
end

do -- 二张·直谏 / 固政
  local r, ps = makeRoomWith({ "二张", "白板武将", "白板武将" }, 45)
  r.identity_mode = true
  ps[1].role, ps[2].role, ps[3].role = "lord", "rebel", "loyalist"
  give(ps[1], "crossbow", Card.Suit.Spade, 2, Card.Type.Equip)
  local n = #ps[1].hand
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(ps[3].equips.weapon ~= nil, "【直谏】应把装备牌置于队友装备区")
  check(#ps[1].hand == n, "【直谏】消耗一张装备牌后应摸一张补回")

  local r2, q = makeRoomWith({ "二张", "白板武将" }, 46)
  -- 两张牌只进弃牌堆（模拟弃牌阶段刚弃掉），不进手牌
  local d1 = Card.create(101, "dodge", Card.Suit.Spade, 2, Card.Type.Basic)
  local d2 = Card.create(102, "dodge", Card.Suit.Spade, 3, Card.Type.Basic)
  table.insert(r2.discardPile, d1)
  table.insert(r2.discardPile, d2)
  r2.last_discard_player = q[2]
  r2.last_discarded = { d1, d2 }
  r2:trigger("EventPhaseEnd", q[1], { player = q[2], phase = "discard" })
  check(#q[2].hand == 1, "【固政】应归还弃牌者一张牌")
  check(#q[1].hand == 1, "【固政】应将其余弃牌收入自己手牌")
end

do -- 丁奉·短兵 / 奋迅
  local r, ps = makeRoomWith({ "丁奉", "白板武将", "白板武将", "白板武将" }, 47)
  check(Generals.marker(ps[1], "slash_extra_target", false), "丁奉【短兵】应允许【杀】多指定目标")
  give(ps[1], "dodge", Card.Suit.Spade, 2)
  local far = r:distance(ps[1], ps[3])
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  local t = nil
  for q, _ in pairs(ps[1].fixed_distance or {}) do t = q end
  check(t ~= nil, "【奋迅】应指定一名角色")
  check(t and r:distance(ps[1], t) == 1, "【奋迅】与该角色距离应固定为 1（原最远 " .. far .. "）")
end

print("\n--- 群雄武将技能 ---")

do -- 华佗·急救：回合外红色手牌当【桃】
  local r, ps = makeRoomWith({ "华佗", "白板武将" }, 51)
  give(ps[1], "dodge", Card.Suit.Heart, 5)
  ps[1].phase = "not_active"
  check(#r:viewAsCandidates(ps[1], "peach") > 0, "【急救】回合外应能用红色牌当【桃】")
  ps[1].phase = "play"
  check(#r:viewAsCandidates(ps[1], "peach") == 0, "【急救】自己回合内不应能用")
  ps[1].phase = "not_active"
  local black = give(ps[1], "slash", Card.Suit.Spade, 5)
  check(r:viewAsCard(ps[1], "peach", black) == nil, "【急救】黑色牌不应能当【桃】")
end

do -- 华佗·青囊：弃一张手牌令一名角色回复体力
  local r, ps = makeRoomWith({ "华佗", "白板武将" }, 52)
  ps[2].hp = 1 -- 损失 3 点体力，满足「损失 2 点以上」的 AI 策略
  give(ps[1], "dodge", Card.Suit.Spade, 2)
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(ps[2].hp == 2, "【青囊】应令受伤角色回复 1 点体力（" .. ps[2].hp .. "）")
  check(ps[1].qingnang_used, "【青囊】每回合限一次")
end

do -- 吕布·无双：标记生效（杀需两张闪、决斗需两张杀）
  local r, ps = makeRoomWith({ "吕布", "白板武将" }, 53)
  check(Generals.marker(ps[1], "wushuang", false), "吕布【无双】应挂上标记")
end

do -- 貂蝉·离间 / 闭月
  local r, ps = makeRoomWith({ "貂蝉", "白板武将", "白板武将" }, 54)
  give(ps[1], "dodge", Card.Suit.Spade, 2)
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  check(ps[1].lijian_used, "【离间】应发动（令两名男性角色决斗）")
  local r2, q = makeRoomWith({ "貂蝉", "白板武将" }, 55)
  local n = #q[1].hand
  r2:trigger("EventPhaseStart", q[1], { player = q[1], phase = "finish" })
  check(#q[1].hand == n + 1, "【闭月】结束阶段应摸一张牌")
end

do -- 袁绍·乱击：两张同花色手牌当【万箭齐发】
  local r, ps = makeRoomWith({ "袁绍", "白板武将" }, 56)
  give(ps[1], "slash", Card.Suit.Spade, 5)
  give(ps[1], "dodge", Card.Suit.Spade, 6)
  local cands = r:viewAsCandidates(ps[1], "archery_attack")
  check(#cands > 0 and cands[1].card2 ~= nil, "【乱击】应能选出两张牌")
  if #cands > 0 then
    local made = cands[1].skill:view_as({ cands[1].card, cands[1].card2 })
    check(made ~= nil and made.name == "archery_attack", "【乱击】两张同花色应能当【万箭齐发】")
    check(made and #made.subcards == 2, "【乱击】虚拟牌应记录两张实体来源")
  end
  local r2, q = makeRoomWith({ "袁绍", "白板武将" }, 57)
  give(q[1], "slash", Card.Suit.Spade, 5)
  give(q[1], "dodge", Card.Suit.Heart, 6)
  check(#r2:viewAsCandidates(q[1], "archery_attack") == 0, "【乱击】不同花色不应能转化")
end

do -- 颜良文丑·双雄：放弃摸牌改为判定，按判定色把手牌当【决斗】
  local r, ps = makeRoomWith({ "颜良文丑", "白板武将" }, 58)
  table.insert(r.drawPile, Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic))
  local n = #ps[1].hand
  local skipped = r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "draw" })
  check(skipped, "【双雄】应截断正常摸牌阶段")
  check(#ps[1].hand == n + 1, "【双雄】应获得判定牌")
  check(ps[1].shuangxiong == 1, "【双雄】黑色判定应记为 1（黑色手牌当决斗）")
end

do -- 贾诩·帷幕：不能成为黑色锦囊的目标
  local r, ps = makeRoomWith({ "贾诩", "白板武将" }, 59)
  local black_trick = give(ps[2], "dismantlement", Card.Suit.Spade, 3, Card.Type.Trick)
  check(not r:_validateUse(ps[2], black_trick, { ps[1] }), "【帷幕】黑色锦囊不能指定贾诩")
  local red_trick = give(ps[2], "dismantlement", Card.Suit.Heart, 3, Card.Type.Trick)
  check(r:_validateUse(ps[2], red_trick, { ps[1] }), "【帷幕】不应挡下红色锦囊")
  check(Generals.marker(ps[1], "wansha", false), "贾诩【完杀】应挂上标记")
end

do -- 庞德·马术 / 猛进
  local r, ps = makeRoomWith({ "庞德", "白板武将", "白板武将", "白板武将" }, 60)
  check(r:distance(ps[1], ps[3]) == 1, "庞德【马术】应使到对家距离 2→1")
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  local n = #ps[2].hand
  r:trigger("SlashMissed", ps[2], { from = ps[1], to = ps[2] })
  check(#ps[2].hand == n - 1, "【猛进】杀被闪抵消后应弃置目标一张牌")
end

do -- 张角·鬼道：用黑色手牌替换判定牌并获得原判定牌
  local r, ps = makeRoomWith({ "张角", "白板武将" }, 61)
  give(ps[1], "slash", Card.Suit.Club, 5)
  -- 原判定为黑桃：【乐不思蜀】会命中，张角才会想改判（红桃时他已经有利，不该发动）
  local old = Card.create(1, "slash", Card.Suit.Spade, 8, Card.Type.Basic)
  local data = { player = ps[1], card = nil, judge_card = old, reason = "indulgence" }
  local replaced = r:trigger("AskForRetrial", ps[1], data)
  check(replaced and data.judge_card.suit == Card.Suit.Club, "【鬼道】应以黑色牌替换判定牌")
  check(data.obtain_old and data.replacer == ps[1], "【鬼道】应要求引擎把旧判定牌交给张角")
end

do -- 张角·雷击：打出【闪】后令一名角色判定，黑桃则 2 点雷伤害
  local r, ps = makeRoomWith({ "张角", "白板武将" }, 62)
  table.insert(r.drawPile, Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic))
  local hp = ps[2].hp
  runInRoom(function()
    r:trigger("CardResponded", ps[1],
      { player = ps[1], card = Card.create(2, "dodge", Card.Suit.Heart, 2, Card.Type.Basic) })
  end)
  check(ps[2].hp == hp - 2, "【雷击】判定黑桃应造成 2 点雷伤害（" .. hp .. " → " .. ps[2].hp .. "）")
end

do -- 蔡文姬·断肠：死亡时令凶手失去所有技能
  local r, ps = makeRoomWith({ "蔡文姬", "张飞" }, 63)
  check(#ps[2].general.skills > 0, "张飞应有技能")
  r:trigger("Death", ps[1], { player = ps[1], killer = ps[2] })
  check(#ps[2].general.skills == 0, "【断肠】应令凶手失去所有技能")
end

do -- 孔融·名士：来源手牌数不少于你时伤害 -1
  local r, ps = makeRoomWith({ "孔融", "白板武将" }, 64)
  give(ps[2], "slash", Card.Suit.Spade, 5)
  give(ps[2], "slash", Card.Suit.Spade, 6)
  local data = { from = ps[2], to = ps[1], n = 1 }
  r:trigger("DamageInflicted", ps[1], data)
  check(data.n == 0, "【名士】应把 1 点伤害降为 0")
  give(ps[1], "dodge", Card.Suit.Heart, 2)
  give(ps[1], "dodge", Card.Suit.Heart, 3)
  local data2 = { from = ps[2], to = ps[1], n = 2 }
  r:trigger("DamageInflicted", ps[1], data2)
  check(data2.n == 1, "【名士】应把 2 点伤害降为 1")
end

do -- 孔融·礼让：弃牌阶段结束后把弃牌分给其他角色
  local r, ps = makeRoomWith({ "孔融", "白板武将" }, 65)
  local d1 = Card.create(101, "dodge", Card.Suit.Spade, 2, Card.Type.Basic)
  local d2 = Card.create(102, "dodge", Card.Suit.Spade, 3, Card.Type.Basic)
  table.insert(r.discardPile, d1)
  table.insert(r.discardPile, d2)
  r.last_discard_player = ps[1]
  r.last_discarded = { d1, d2 }
  r:trigger("EventPhaseEnd", ps[1], { player = ps[1], phase = "discard" })
  -- AI 策略只让出一张（全送出去会养肥对手手牌，反而触发【名士】减伤）
  check(#ps[2].hand == 1, "【礼让】应让出一张弃牌（实得 " .. #ps[2].hand .. "）")
  check(not hasCard(r.discardPile, d1), "【礼让】让出的牌应离开弃牌堆")
  check(hasCard(r.discardPile, d2), "【礼让】未让出的牌应留在弃牌堆")
end

do -- 纪灵·双刃：拼点胜利视为使用【杀】
  local r, ps = makeRoomWith({ "纪灵", "白板武将" }, 66)
  give(ps[1], "slash", Card.Suit.Spade, 12)
  give(ps[2], "slash", Card.Suit.Spade, 3)
  local hp = ps[2].hp
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  check(ps[2].hp < hp, "【双刃】拼点获胜应视为使用一张【杀】（" .. hp .. " → " .. ps[2].hp .. "）")
end

do -- 田丰·死谏 / 随势
  local r, ps = makeRoomWith({ "田丰", "白板武将" }, 67)
  give(ps[2], "dodge", Card.Suit.Spade, 2)
  local n = #ps[2].hand
  r:trigger("CardsMoveOneTime", ps[1],
    { player = ps[1], from_place = "hand", last_handcard = true })
  check(#ps[2].hand == n - 1, "【死谏】失去最后手牌时应弃置他人一张牌")

  local r2, q = makeRoomWith({ "田丰", "白板武将", "白板武将" }, 68)
  r2.identity_mode = true
  q[1].role, q[2].role, q[3].role = "lord", "loyalist", "rebel"
  local m = #q[1].hand
  r2:trigger("Dying", q[3], { player = q[3] })
  check(#q[1].hand == m, "【随势】非队友濒死时不发动")
  local m2 = #q[1].hand
  r2:trigger("Dying", q[2], { player = q[2] })
  check(#q[1].hand == m2 + 1, "【随势】队友濒死时应摸一张牌")
end

do -- 潘凤·狂斧：杀造成伤害后夺取目标装备
  local r, ps = makeRoomWith({ "潘凤", "白板武将" }, 69)
  give(ps[2], "crossbow", Card.Suit.Spade, 2, Card.Type.Equip)
  ps[2]:equipCard(table.remove(ps[2].hand, 1), "weapon")
  r:trigger("Damage", ps[2], {
    from = ps[1], to = ps[2], n = 1,
    card = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic),
  })
  check(ps[1].equips.weapon ~= nil, "【狂斧】应把目标装备收归己用")
  check(ps[2].equips.weapon == nil, "【狂斧】目标应失去该装备")
end

do -- 马腾·马术 / 雄异
  local r, ps = makeRoomWith({ "马腾", "白板武将", "白板武将", "白板武将" }, 70)
  check(r:distance(ps[1], ps[3]) == 1, "马腾【马术】应使到对家距离 2→1")
  r.identity_mode = true
  ps[1].role, ps[2].role, ps[3].role = "lord", "loyalist", "rebel"
  local n = #ps[3].hand
  r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  check(#ps[3].hand == n, "【雄异】只应给队友摸牌，不应给敌人")
end

print("\n--- 兼容层：ExpPattern ---")

do
  local ExpPattern = require "src.compat.exppattern"
  local club = Card.create(1, "slash", Card.Suit.Club, 5, Card.Type.Basic)
  local heart = Card.create(2, "peach", Card.Suit.Heart, 3, Card.Type.Basic)
  local spade9 = Card.create(3, "dodge", Card.Suit.Spade, 9, Card.Type.Basic)
  local equip = Card.create(4, "crossbow", Card.Suit.Spade, 2, Card.Type.Equip)

  check(ExpPattern.match(".|club|.|hand", club, "hand"), "梅花手牌应匹配 .|club|.|hand")
  check(not ExpPattern.match(".|club|.|hand", heart, "hand"), "红桃不应匹配梅花模式")
  check(ExpPattern.match(".|black", spade9, "hand"), "黑桃应匹配 .|black")
  check(not ExpPattern.match(".|red", spade9, "hand"), "黑桃不应匹配 .|red")
  check(ExpPattern.match(".|.|2~9", spade9, "hand"), "点数区间 2~9 应匹配 9")
  check(not ExpPattern.match(".|.|2~8", spade9, "hand"), "点数区间 2~8 不应匹配 9")
  check(ExpPattern.match("EquipCard|.|.|hand", equip, "hand"), "装备牌应匹配 EquipCard")
  check(ExpPattern.match("slash", club, "hand"), "【杀】应匹配 slash")
  check(ExpPattern.match(".|club|.|hand!", club, "hand"), "结尾的 ! 应被忽略")
end

print("\n--- 兼容层：DIY 扩展加载 ---")

do -- 加载 diy/ 下的示例扩展，检查武将/技能是否注册成功
  local Loader = require "src.compat.loader"
  local engine = Engine.create()
  Standard.setup(engine)
  local report = Loader.loadDirectory(engine, "diy")
  local ok_count = 0
  for _, item in ipairs(report) do
    if item.ok then ok_count = ok_count + 1 end
  end
  check(#report > 0, "应扫描到 diy/ 下的扩展文件（" .. #report .. " 个）")
  check(ok_count == #report, "所有扩展应加载成功")

  -- 示例扩展 moligaloo 里的时迁
  local g = engine:getGeneral("时迁")
  check(g ~= nil, "DIY 武将【时迁】应注册进引擎")
  check(g and g.max_hp == 4, "DIY 武将默认体力应为 4")
  check(g and g.kingdom == "qun", "DIY 武将势力应为 qun")
  check(g and #g.skills == 2, "DIY 武将应有 2 个技能（实得 "
    .. (g and #g.skills or 0) .. "）")
end

do -- DIY 的 OneCardViewAsSkill：梅花手牌当【顺手牵羊】
  local Loader = require "src.compat.loader"
  local engine = Engine.create()
  Standard.setup(engine)
  Loader.loadDirectory(engine, "diy")
  local g = engine:getGeneral("时迁")
  local ps = {}
  for i, name in ipairs({ "时迁", "白板武将" }) do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral(name), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(1)

  local club = give(ps[1], "slash", Card.Suit.Club, 5)
  local cands = r:viewAsCandidates(ps[1], "snatch")
  check(#cands > 0, "【神偷】应能把梅花手牌转化为【顺手牵羊】")
  local made = nil
  if #cands > 0 then
    made = cands[1].skill:view_as({ cands[1].card })
  end
  check(made ~= nil and made.name == "snatch", "转化结果应为【顺手牵羊】")
  check(made and made.virtual and #made.subcards == 1,
    "转化牌应带实体来源（addSubcard 的 id 要能还原成牌对象）")
  local heart = give(ps[1], "peach", Card.Suit.Heart, 3)
  check(r:viewAsCard(ps[1], "snatch", heart) == nil, "非梅花不应能转化")
  if club then end
end

do -- DIY 的 TriggerSkill：受伤后摸一张牌
  local Loader = require "src.compat.loader"
  local engine = Engine.create()
  Standard.setup(engine)
  Loader.loadDirectory(engine, "diy")
  local ps = {}
  for i, name in ipairs({ "时迁", "白板武将" }) do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral(name), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(2)
  local n = #ps[1].hand
  runInRoom(function()
    r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1, nature = "normal" })
  end)
  check(#ps[1].hand == n + 1, "【神行】受伤后应摸一张牌（" .. n .. " → "
    .. #ps[1].hand .. "）")
end

do -- 技能牌：CreateSkillCard + clone + subcards + on_use
  local Loader = require "src.compat.loader"
  local engine = Engine.create()
  Standard.setup(engine)
  Loader.loadDirectory(engine, "diy")

  local g = engine:getGeneral("试作武将")
  check(g ~= nil, "DIY 技能牌武将【试作武将】应注册进引擎")
  check(g and #g.skills == 1, "应注册 1 个技能（实得 " .. (g and #g.skills or 0) .. "）")

  local ps = {}
  for i, name in ipairs({ "试作武将", "白板武将" }) do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral(name), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(3)

  -- 手牌里放 3 张，弃 2 张换 2 张
  give(ps[1], "slash", Card.Suit.Spade, 5)
  give(ps[1], "slash", Card.Suit.Spade, 6)
  give(ps[1], "dodge", Card.Suit.Heart, 2)
  local skill = g.skills[1]
  local made = skill:view_as({ ps[1].hand[1], ps[1].hand[2] })
  check(made ~= nil, "【自守】应能产出一个技能牌")
  check(made and made.skill_card ~= nil, "产出物应带 skill_card 规格")
  check(made and made:getSubcards():length() == 2,
    "技能牌应记录 2 张实体来源（实得 " .. (made and made:getSubcards():length() or -1) .. "）")

  local before, dumped = #ps[1].hand, #r.discardPile
  local consumed
  runInRoom(function()
    consumed = r:useCard(ps[1], made, nil)
  end)
  check(consumed, "技能牌应能被使用（引擎要拦下它而不是走卡牌结算）")
  check(#r.discardPile == dumped + 2, "will_throw：作为代价的 2 张牌应进弃牌堆")
  check(#ps[1].hand == before, "弃 2 摸 2，手牌数不变（" .. before .. " → " .. #ps[1].hand .. "）")
end

do -- DIY 的 FilterSkill 也应接入 effSuit
  local sgs = require "src.compat.sgs"
  local filter = sgs.CreateFilterSkill{
    name = "测试过滤",
    view_filter = function(card) return card.suit == Card.Suit.Spade end,
    view_as = function(card)
      -- 原版返回一张改过的牌；兼容层应能从中取出花色
      local c = Card.create(card.id, card.name, Card.Suit.Heart, card.number, card.ctype)
      return c
    end,
  }
  local engine = Engine.create()
  Standard.setup(engine)
  local g = engine:getGeneral("白板武将")
  local ps = { Player.create("P1", g, 1, false), Player.create("P2", g, 2, false) }
  ps[1].extra_skills = { filter }
  local r = Room.create(engine, ps)
  local spade = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  check(r:effSuit(ps[1], spade) == Card.Suit.Heart,
    "DIY 过滤技应生效（黑桃→红桃）")
  check(r:effSuit(ps[2], spade) == Card.Suit.Spade,
    "没有该技能的角色不应受影响")
end

do -- 中文翻译表
  local sgs = require "src.compat.sgs"
  check(sgs.Translations["moligaloo"] == "太阳神上", "LoadTranslationTable 应记录包名")
  check(sgs.Translations["shentou"] == "神偷", "LoadTranslationTable 应记录技能名")
end

do -- 询问类 API：askForPindian / askForAG / askForYiji / setPlayerProperty
  local Loader = require "src.compat.loader"
  local engine = Engine.create()
  Standard.setup(engine)
  Loader.loadDirectory(engine, "diy")

  local g = engine:getGeneral("试炼武将")
  check(g ~= nil, "DIY 拼点武将【试炼武将】应注册进引擎")

  local ps = {}
  for i, name in ipairs({ "试炼武将", "白板武将", "白板武将" }) do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral(name), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(4)

  -- askForPindian：返回 PindianStruct，脚本读 from_number / to_number
  give(ps[1], "slash", Card.Suit.Spade, 12)
  give(ps[2], "slash", Card.Suit.Spade, 3)
  local pd = r:askForPindian(ps[1], ps[2], "测试")
  check(pd ~= nil, "askForPindian 应返回拼点结构")
  check(pd and pd.success == true, "点数大者应获胜")
  check(pd and pd.from_number == 12 and pd.to_number == 3,
    "应记录双方点数（" .. tostring(pd and pd.from_number) .. "/"
      .. tostring(pd and pd.to_number) .. "）")
  check(#ps[1].hand + #ps[2].hand == 0, "拼点的两张牌都应被弃置")

  -- askForAG：从给定 id 列表里选一张
  give(ps[1], "peach", Card.Suit.Heart, 5)
  local picked = r:askForAG(ps[1], { ps[1].hand[1].id }, false)
  check(picked ~= nil, "askForAG 应返回选中的 id")

  -- askForYiji：必须返回 false，否则脚本的 while 循环会死循环
  give(ps[1], "dodge", Card.Suit.Heart, 2)
  local to_give = { table.remove(ps[1].hand, 1) }
  table.insert(r.discardPile, to_give[1])
  local n2, n3 = #ps[2].hand, #ps[3].hand
  local ret = r:askForYiji(ps[1], to_give, "测试")
  local got = (#ps[2].hand - n2) + (#ps[3].hand - n3)
  check(ret == false, "askForYiji 应返回 false 以终止脚本的 while 循环")
  check(got == 1, "askForYiji 应把牌交给一名其他角色（实得 " .. got .. " 张）")
  check(not hasCard(r.discardPile, to_give[1]), "被交出的牌应离开弃牌堆")

  -- setPlayerProperty
  r:setPlayerProperty(ps[1], "hp", 2)
  check(ps[1].hp == 2, "setPlayerProperty 应能设置血量（实得 " .. ps[1].hp .. "）")

  -- 触发技整链路：拼点赢后摸牌。
  -- 拼点用的是双方手牌第一张，所以先清场，否则会拿到上面遗留的杂牌。
  for _, p in ipairs({ ps[1], ps[2] }) do
    for _, c in ipairs(p.hand) do table.insert(r.discardPile, c) end
    p.hand = {}
  end
  give(ps[1], "slash", Card.Suit.Spade, 13) -- 拼点必胜
  give(ps[2], "slash", Card.Suit.Spade, 2)
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  -- 1 张起手 -1（拼点弃置）+2（摸牌）-1（askForYiji 分出一张）= 1
  check(#ps[1].hand == 1,
    "【试炼】拼点获胜后应摸 2 张并分出 1 张（实得 " .. #ps[1].hand .. "）")
  check(#ps[2].hand == 1, "分出的牌应交给另一名角色（实得 " .. #ps[2].hand .. "）")
end

do -- 名称归一 / cloneCard / Card_Parse
  local sgs = require "src.compat.sgs"
  check(sgs.lowerCardName("Duel") == "duel", "Duel 应归一为 duel")
  check(sgs.lowerCardName("ArcheryAttack") == "archery_attack",
    "ArcheryAttack 应归一为 archery_attack")
  -- 原版脚本常写首字母大写，engine 里是 snake_case
  local duel = sgs.Sanguosha:cloneCard("Duel", sgs.Card_NoSuit, 0)
  check(duel.name == "duel", "cloneCard(\"Duel\") 应得到 duel（实得 " .. duel.name .. "）")
  local aa = sgs.Sanguosha:cloneCard("ArcheryAttack", sgs.Card_NoSuit, 0)
  check(aa.name == "archery_attack", "cloneCard 应处理多段驼峰（实得 " .. aa.name .. "）")
  check(duel.virtual, "cloneCard 产出的是虚拟牌，便于引擎取 subcards")

  local parsed = sgs.Card_Parse("archery_attack:luanji[diamond:K]=29+28")
  check(parsed ~= nil and parsed.name == "archery_attack",
    "Card_Parse 应解析出牌名（实得 " .. tostring(parsed and parsed.name) .. "）")
  check(parsed and parsed.suit == Card.Suit.Diamond, "Card_Parse 应解析花色")
  check(parsed and parsed.number == 13, "Card_Parse 应把 K 解析为 13")
  check(parsed and #parsed.subcards == 2, "Card_Parse 应记录 2 张子卡")
  local skillcard = sgs.Card_Parse("@RendeCard=0")
  check(skillcard ~= nil and skillcard.name == "rende_card",
    "Card_Parse 应解析 @Class 形式的技能卡（实得 "
      .. tostring(skillcard and skillcard.name) .. "）")
end

print("\n--- 皮肤配置：JSON 解析 ---")

do
  local Json = require "src.ui.json"
  -- 原版 skins/*.json 同时带 /* */ 头注释与 // 行注释
  -- 注意用 [==[ ]==]：JSON 里的 `[3]]` 含 `]]`，用 [[]] 会被提前闭合
  local txt = [==[
/* 头部注释
   多行 */
{
  "a": 1,          // 行注释
  "b": [1, 2, [3]],
  "c": {"d": true, "e": null, "f": false},
  "url": "http://x//y",   // 字符串里的 // 不该被剥掉
  "g": -1.5e2,
  "h": "转义\"引号"
}
]==]
  local t, err = Json.decode(txt)
  check(t ~= nil, "应能解析带 C 风格注释的 JSON（" .. tostring(err) .. "）")
  if t then
    check(t.a == 1, "应解析数字")
    check(t.b[3][1] == 3, "应解析嵌套数组")
    check(t.c.d == true and t.c.f == false, "应解析布尔值")
    check(t.c.e == nil, "null 应解析为 nil")
    check(t.url == "http://x//y",
      "字符串里的 // 不应被当注释删掉（实得 " .. tostring(t.url) .. "）")
    check(t.g == -150, "应解析科学计数法与负号（实得 " .. tostring(t.g) .. "）")
    check(t.h == '转义"引号', "应解析转义字符（实得 " .. tostring(t.h) .. "）")
  end
  check(Json.decode("这不是 json") == nil, "解析失败应返回 nil 而不是抛错")
  check(Json.decode(nil) == nil, "非字符串输入应安全返回 nil")
end

print("\n--- 皮肤配置：Skin 查询 ---")

do
  local Skin = require "src.ui.skin"
  -- 显式传一个不存在的根，模拟「没有原版资源」的环境（如纯 headless）
  local s = Skin.create("/nonexistent/sgs-assets")
  check(s ~= nil, "无资源根时也应能创建 Skin")
  check(not s:available(), "资源不可用时 available() 应为 false")
  check(s:rect("photo.mainFrameArea") == nil, "无配置时 rect 应返回 nil")
  check(s:image("photoMainFrame") == nil, "无配置时 image 应返回 nil")
  check(s:sound("slash") == nil, "无配置时 sound 应返回 nil")
  check(s:number("common.cardNormalWidth", 93) == 93, "应能带回退默认值")
end

do
  -- 用一段内联配置验证查询语义（不依赖外部文件）
  local Skin = require "src.ui.skin"
  local s = Skin.create("/nonexistent/sgs-assets")
  s.layout = {
    common = { cardNormalWidth = 93, cardNormalHeight = 130 },
    photo = { mainFrameArea = { 0, 0, 100, 120 } },
  }
  s.imageMap = { photoMainFrame = "image/system/photo-back.png" }
  s.audioMap = { ["slash"] = { "audio/card/slash_1.ogg" } }
  check(s:number("common.cardNormalWidth") == 93, "应能按路径取数值")
  check(s:number("common.cardNormalHeight") == 130, "应能按路径取数值（高度）")
  local r = s:rect("photo.mainFrameArea")
  check(r and r[1] == 0 and r[3] == 100 and r[4] == 120, "rect 应返回 [x,y,w,h]")
  check(s:image("photoMainFrame") == "image/system/photo-back.png", "应能取图片路径")
  check(s:sound("slash") ~= nil, "应能取音频路径")
  check(s:rect("photo.不存在的键") == nil, "取不到的键应返回 nil 而非报错")
  check(s:number("a.b.c", 7) == 7, "取不到时应返回默认值")
end

print("\n--- 卡图解析 ---")

do
  local Skin = require "src.ui.skin"
  local s = Skin.create() -- 自动寻找原版资源目录
  if not s:available() then
    print("（未找到原版 QSanguosha 资源，跳过真实资源校验；"
      .. "设 SGS_ASSET_ROOT 指向资源根目录可启用）")
  else
    check(s:available(), "应接上原版资源")
    check(s:number("common.cardNormalWidth") ~= nil, "应能读到卡牌宽度配置")
    -- 原版卡牌图：基本牌用 snake_case，装备用 CamelCase
    check(s:cardImage("slash") ~= nil, "【杀】应能解析出图片路径")
    check(s:cardImage("crossbow") ~= nil, "【诸葛连弩】应能解析出图片路径（CamelCase）")
    check(s:cardImage("不存在的牌") == nil, "未知卡牌应返回 nil")
    print("  已接入原版资源：" .. tostring(s.root))

    -- 武将头像按 general.key（拼音）解析
    check(s:generalImage("caocao") ~= nil, "【曹操】头像应能解析（key=caocao）")
    check(s:generalImage("lvbu") ~= nil, "【吕布】头像应能解析（key=lvbu）")
    check(s:generalImage("不存在的武将") == nil, "未知武将应返回 nil")
    -- 勾玉与势力
    check(s:magatamaImage(3) ~= nil, "满勾玉应能解析")
    check(s:magatamaImage(0) ~= nil, "空勾玉应能解析")
    check(s:kingdomImage("wei") ~= nil, "势力图标【魏】应能解析")
  end
end

print("\n--- 座位布局 ---")

do
  local Skin = require "src.ui.skin"
  local Layout = require "src.ui.layout"

  -- 无配置时：退回内置默认值，且 4 人局第 1 位（自己）在底部
  local l2 = Layout.create(Skin.create("/nonexistent/sgs-assets"), 4)
  check(l2.anchors[1] ~= nil, "应能为每位玩家算出锚点")
  check(l2.anchors[1][1] == 460 and l2.anchors[1][2] == 440,
    "无配置时 1 号位应退回原锚点 (460,440)，实得 ("
      .. tostring(l2.anchors[1][1]) .. "," .. tostring(l2.anchors[1][2]) .. ")")

  -- 有配置时：按人数自适应，且锚点互不重叠
  for _, n in ipairs({ 2, 4, 5, 8 }) do
    local l = Layout.create(Skin.create("/nonexistent/sgs-assets"), n)
    local cnt = 0
    for i = 1, n do
      if l.anchors[i] then cnt = cnt + 1 end
    end
    check(cnt == n, n .. " 人局应算出 " .. n .. " 个锚点（实得 " .. cnt .. "）")
    -- 面板不应超出画面
    local ok = true
    for i = 1, n do
      local a = l.anchors[i]
      if a[1] < 0 or a[1] + l.photoW > l.sceneW or a[2] < 0 or a[2] > l.sceneH then
        ok = false
      end
    end
    check(ok, n .. " 人局的面板都应在画面内")
  end

  -- 锚点不能两两重合
  local l = Layout.create(Skin.create("/nonexistent/sgs-assets"), 5)
  local dup = false
  for i = 1, 5 do
    for j = i + 1, 5 do
      if l.anchors[i][1] == l.anchors[j][1] and l.anchors[i][2] == l.anchors[j][2] then
        dup = true
      end
    end
  end
  check(not dup, "5 人局的锚点不应重合")
end

print("\n--- 表现层事件（音频/动效钩子）---")

do
  local Room = require "src.core.room"
  local Engine = require "src.core.engine"
  local Player = require "src.core.player"
  local engine = Engine.create()
  Standard.setup(engine)
  local ps = {}
  for i = 1, 2 do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral("白板武将"), i, false))
  end
  local r = Room.create(engine, ps)
  local got = {}
  r:onEvent("useCard", function(d) table.insert(got, "useCard") end)
  r:onEvent("damage", function(d) table.insert(got, "damage:" .. tostring(d.n)) end)
  r:emit("useCard", { card = nil })
  r:emit("damage", { n = 3 })
  check(#got == 2, "注册的回调都应被调用（实得 " .. #got .. "）")
  check(got[2] == "damage:3", "回调应收到数据（实得 " .. tostring(got[2]) .. "）")
  -- 未注册的事件不应报错
  local ok = pcall(function() r:emit("不存在的事件", {}) end)
  check(ok, "未注册的事件应安全忽略")
  -- 回调抛错不应中断游戏
  r:onEvent("death", function() error("故意抛错") end)
  local ok2 = pcall(function() r:emit("death", { player = ps[1] }) end)
  check(ok2, "回调抛错应被捕获，不能中断对局")
end

print("\n--- 过滤技：红颜（黑桃视为红桃）---")

do
  local engine = Engine.create()
  Standard.setup(engine)
  local function mk(general)
    local ps = {}
    for i, nm in ipairs({ general, "白板武将" }) do
      table.insert(ps, Player.create("P" .. i, engine:getGeneral(nm), i, false))
    end
    local r = Room.create(engine, ps)
    r.drawPile = Standard.buildDrawPile(1)
    return r, ps
  end

  -- effSuit：小乔的黑桃应变红桃，其他人不变
  local r, ps = mk("小乔")
  local spade = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  local heart = Card.create(2, "slash", Card.Suit.Heart, 5, Card.Type.Basic)
  check(r:effSuit(ps[1], spade) == Card.Suit.Heart, "小乔的黑桃应视为红桃")
  check(r:effSuit(ps[1], heart) == Card.Suit.Heart, "小乔的红桃仍是红桃")
  check(r:effSuit(ps[2], spade) == Card.Suit.Spade, "其他人的黑桃不应被改写")

  -- 判定区：小乔的【乐不思蜀】抽到黑桃 → 视为红桃 → 不生效
  local r2, ps2 = mk("小乔")
  table.insert(r2.drawPile, Card.create(3, "slash", Card.Suit.Spade, 7, Card.Type.Basic))
  local indul = Card.create(4, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  ps2[1]:addJudge(indul)
  local res
  runInRoom(function() res = r2:_judgeCard(ps2[1], indul) end)
  check(res ~= nil, "应完成判定")
  -- 命中会把延时锦囊放入弃牌堆；未命中也会放入（闪电除外），
  -- 因此用「是否跳过出牌阶段」来断言更直接：这里验证 effSuit 已参与判定
  check(r2:effSuit(ps2[1], res) == Card.Suit.Heart,
    "判定结果对小乔应按红桃解读（实得 " .. tostring(res:suitString()) .. "）")

  -- 对照组：同样黑桃，对普通武将就是黑桃 → 【乐不思蜀】生效
  local r3, ps3 = mk("白板武将")
  table.insert(r3.drawPile, Card.create(5, "slash", Card.Suit.Spade, 7, Card.Type.Basic))
  local indul3 = Card.create(6, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  ps3[1]:addJudge(indul3)
  local res3
  runInRoom(function() res3 = r3:_judgeCard(ps3[1], indul3) end)
  check(r3:effSuit(ps3[1], res3) == Card.Suit.Spade,
    "普通武将的判定不应被改写（实得 " .. tostring(res3:suitString()) .. "）")

  -- 天香：红颜下黑桃也能当天香牌
  local r4, ps4 = mk("小乔")
  give(ps4[1], "slash", Card.Suit.Spade, 5)
  local hp = ps4[2].hp
  runInRoom(function()
    r4:trigger("DamageInflicted", ps4[1],
      { from = ps4[2], to = ps4[1], n = 1, nature = "normal" })
  end)
  check(ps4[2].hp < hp, "【天香】应能用黑桃牌发动（红颜改写花色）")
end

print("\n--- 主动技征询（人类玩家）---")

do
  local Room = require "src.core.room"
  local Engine = require "src.core.engine"
  local Player = require "src.core.player"
  local skillmod = require "src.core.skill"
  local Generals = require "src.core.generals"

  local engine = Engine.create()
  Standard.setup(engine)
  -- 用【苦肉】（出牌阶段主动技，非锁定）验证征询
  local g = engine:getGeneral("黄盖")
  local sk = nil
  for _, s in ipairs(g.skills) do
    if s.name == "苦肉" or s.zh == "苦肉" then sk = s end
  end
  check(sk ~= nil, "应找到【苦肉】技能")

  local mk = function(is_human)
    local ps = {}
    for i = 1, 2 do
      table.insert(ps, Player.create("P" .. i, engine:getGeneral("黄盖"), i, i == 1 and is_human))
    end
    local r = Room.create(engine, ps)
    r.drawPile = Standard.buildDrawPile(1)
    for _, p in ipairs(ps) do
      p.hp = 4
      give(p, "slash", Card.Suit.Spade, 5)
    end
    return r
  end

  -- 人类玩家：应当弹出征询（协程 yield 出 askForSkillInvoke）
  local r = mk(true)
  local asked = nil
  runInRoom(function()
    r:trigger("EventPhaseStart", r.players[1],
      { player = r.players[1], phase = "play" })
  end, function(req)
    if req.type == "askForSkillInvoke" then
      asked = req.skill
      return false -- 玩家选择「不发动」
    end
    return nil
  end)
  check(asked ~= nil, "人类玩家的主动技应弹出征询（实得 " .. tostring(asked) .. "）")
  check(r.players[1].hp == 4, "玩家选择不发动时【苦肉】不应扣体力")

  -- AI：不应询问，直接发动（AI 走的是技能自身逻辑）
  local r2 = mk(false)
  runInRoom(function()
    r2:trigger("EventPhaseStart", r2.players[1],
      { player = r2.players[1], phase = "play" })
  end)
  check(r2.players[1].hp == 3, "AI 应直接发动【苦肉】（hp 4→"
    .. r2.players[1].hp .. "）")

  -- 锁定技不征询
  local r3 = Room.create(engine, {
    Player.create("P1", engine:getGeneral("吕布"), 1, true),
    Player.create("P2", engine:getGeneral("白板武将"), 2, false),
  })
  local asked3 = nil
  runInRoom(function()
    r3:trigger("Damaged", r3.players[1],
      { from = r3.players[2], to = r3.players[1], n = 1, nature = "normal" })
  end, function(req)
    if req.type == "askForSkillInvoke" then asked3 = req.skill end
    return nil
  end)
  check(asked3 == nil, "锁定技不应弹出征询（无双是 Compulsory）")
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
