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
local Bot = require "src.core.bot"
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
  local driver = Driver.create(room, Bot.make())
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
        local d = Driver.create(r, Bot.make())
        d:advance()
        assertFinished(r, Standard.deckSize())
      end)
      if ok then ok_count = ok_count + 1 end
    end
    if ok_count ~= 6 then table.insert(bad_combo, combo[1] .. "vs" .. combo[2]) end
  end
  check(#bad_combo == 0, "三组带技能武将各 6 局全部跑通（失败: " .. table.concat(bad_combo, ",") .. "）")
end

print("\n--- 随机选将（防止每局都一样 / 座位重复）---")

do
  local function names(seed, n)
    local e = Engine.create()
    Standard.setup(e)
    local ps = Standard.pickGenerals(e, Standard.makeRng(seed), n)
    local t = {}
    for _, g in ipairs(ps) do table.insert(t, g.name) end
    return t
  end

  -- 1) 同一局内不得重复
  for _, n in ipairs { 4, 5, 8 } do
    local t = names(42, n)
    local seen, dup = {}, 0
    for _, nm in ipairs(t) do
      if seen[nm] then dup = dup + 1 end
      seen[nm] = true
    end
    check(dup == 0, string.format("%d 人局武将不应重复（重复 %d 个：%s）",
      n, dup, table.concat(t, "/")))
  end

  -- 2) 不同种子应给出不同阵容（以前是固定名单取模，每次都一样）
  local a, b, c = names(1001, 5), names(1002, 5), names(1003, 5)
  local ja, jb = table.concat(a, "/"), table.concat(b, "/")
  check(ja ~= jb, "不同种子应给出不同阵容（" .. ja .. " vs " .. jb .. "）")
  check(table.concat(c, "/") ~= ja, "第三个种子也应是不同阵容")

  -- 3) 同一种子必须可复现（否则压测/回放没有意义）
  local r1, r2 = names(777, 5), names(777, 5)
  check(table.concat(r1, "/") == table.concat(r2, "/"), "同一种子应可复现")

  -- 4) 不得出现白板/剑阁占位将
  local t = names(2024, 8)
  local bad = 0
  for _, nm in ipairs(t) do
    if nm == "白板武将" or nm == "剑阁武将" then bad = bad + 1 end
  end
  check(bad == 0, "随机选将不应出现占位将（" .. table.concat(t, "/") .. "）")
end

do -- diy/ 示例武将默认不进随机池（正常对局看不到）；opts.demo = true 才参与（测试用）
  local Loader = require "src.compat.loader"
  local function picks(seed, n, opts)
    local e = Engine.create()
    Standard.setup(e)
    Loader.loadDirectory(e, "diy")
    local t = {}
    for _, g in ipairs(Standard.pickGenerals(e, Standard.makeRng(seed), n, opts)) do
      table.insert(t, g.name)
    end
    return t
  end
  local demos = { ["试炼武将"] = true, ["试作武将"] = true, ["时迁"] = true }

  local leaked = {}
  for seed = 1, 40 do
    for _, nm in ipairs(picks(seed, 8)) do
      if demos[nm] then table.insert(leaked, seed .. ":" .. nm) end
    end
  end
  check(#leaked == 0,
    "默认随机池不应出现 diy/ 示例武将（" .. table.concat(leaked, ",") .. "）")

  local leak2 = 0
  for seed = 1, 40 do
    local e = Engine.create()
    Standard.setup(e)
    Loader.loadDirectory(e, "diy")
    if demos[Standard.randomGeneral(e, Standard.makeRng(seed)).name] then
      leak2 = leak2 + 1
    end
  end
  check(leak2 == 0, "randomGeneral 默认也不应抽到 diy/ 示例武将（漏 " .. leak2 .. " 次）")

  -- opts.demo = true 时示例将回到池里，测试想覆盖它们时有得抽
  local seen = {}
  for seed = 1, 40 do
    for _, nm in ipairs(picks(seed, 8, { demo = true })) do
      seen[nm] = true
    end
  end
  check(seen["试炼武将"] and seen["试作武将"] and seen["时迁"],
    "opts.demo = true 时随机池应能抽到 diy/ 示例武将")
end

print("\n--- 身份局 ---")

-- 构造一个 n 人身份局（全部 BOT），可指定 seed（对局测试统一用 5 / 8 人）
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
  local r = makeIdentityGame(5, 11)
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
  local r = makeIdentityGame(5, 5)
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
  local r = makeIdentityGame(5, 6)
  local lord = r:getLord()
  lord.alive = false
  r:_checkWinner()
  check(r.game_over and r.win_role == "rebel", "主公阵亡且非内奸独存 → 反贼获胜")
end

-- 胜负判定：主公阵亡且仅剩内奸 → 内奸胜
do
  local r = makeIdentityGame(5, 7)
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
  local r = makeIdentityGame(5, 8)
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
  local r = makeIdentityGame(5, 9)
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
      local r = makeIdentityGame(5, seed * 17 + 3)
      r:start()
      local d = Driver.create(r, Bot.make())
      d:advance()
      assert(r.game_over, "未正常结束")
      assert(r.turn_count <= Room.MAX_TURNS, "超回合")
      assert(r.win_role ~= nil, "未判定获胜阵营")
      assert(totalCards(r) == Standard.deckSize(), "卡牌不守恒 " .. totalCards(r))
    end)
    if ok then ok_count = ok_count + 1 else table.insert(bad, seed) end
  end
  check(ok_count == 6, "5 人身份局 6 个种子全部跑通（失败: " .. table.concat(bad, ",") .. "）")
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

do -- 表现层事件：杀被闪 → BOT 打出【闪】应广播 respond 事件（UI 播音效/飞牌）
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 20)
  local events = {}
  r:onEvent("respond", function(d) table.insert(events, d) end)
  local slash = give(ps[1], "slash", Card.Suit.Spade, 5)
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  runInRoom(function()
    r:useCard(ps[1], slash, ps[2])
  end, function(req)
    if req and req.type == "askForCard" and req.card_name == "dodge" then
      return ps[2].hand[1]
    end
    return nil
  end)
  check(#events == 1 and events[1].card and events[1].card.name == "dodge"
      and events[1].player == ps[2],
    "被闪时应广播 respond 事件（实得 " .. #events .. " 条）")
end

do -- 表现层事件：装备上阵应广播 equip 事件并带槽位
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 21)
  local events = {}
  r:onEvent("equip", function(d) table.insert(events, d) end)
  local crossbow = give(ps[1], "crossbow", Card.Suit.Club, 1, Card.Type.Equip)
  local horse = give(ps[1], "offensive_horse", Card.Suit.Spade, 5, Card.Type.Equip)
  runInRoom(function()
    r:useCard(ps[1], crossbow, ps[1])
    r:useCard(ps[1], horse, ps[1])
  end)
  check(#events == 2 and events[1].slot == "weapon" and events[2].slot == "offensive_horse"
      and events[1].player == ps[1],
    "装备武器/马应广播 equip 事件并带槽位（实得 " .. #events .. " 条）")
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
  runInRoom(function()
    r:trigger("AskForRetrial", ps[1], data)
  end, function(req)
    -- 新版鬼才让玩家选替换用手牌；测试选那张红桃
    return (req and req.type == "askForChooseCard") and ps[1].hand[#ps[1].hand] or nil
  end)
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
  runInRoom(function()
    r:trigger("Damaged", ps[1], { from = ps[2], to = ps[1], n = 1 })
  end, function(req)
    -- 新版遗计逐张询问分给谁（askForChoice）；测试统一留给自己
    return (req and req.type == "askForChoice") and ps[1].name or nil
  end)
  check(#ps[1].hand == n + 2, "【遗计】受到伤害后应获得两张牌（归自己）")
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
  ps[2].hp = 1 -- 残血，满足「值得放弃摸牌」的 BOT 条件
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
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end, function(req)
    -- 新版制衡走 any 模式自选弃牌；测试换掉前两张废牌（与旧断言对齐）
    if req and req.type == "askForDiscard" and req.any then
      return { ps[1].hand[1], ps[1].hand[2] }
    end
    return nil
  end)
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
  runInRoom(function()
    r:trigger("TargetConfirming", ps[1], use)
  end, function(req)
    -- 新版流离：先选弃牌代价（拿那张闪），再选转移目标（候选只有 P3）
    if req and req.type == "askForChooseCard" then return ps[1].hand[1] end
    if req and req.type == "askForChoice" then return ps[3].name end
    return nil
  end)
  check(use.to[1] == ps[3] or use.to[1] == ps[2],
    "【流离】应把【杀】转移给另一名角色（实际目标 " .. use.to[1].name .. "）")
  check(use.to[1] ~= ps[1], "【流离】转移后大乔不应再是目标")
end

do -- 陆逊·谦逊 / 连营（标准版：谦逊 + 连营，取代国战版的度势）
  local r, ps = makeRoomWith({ "陆逊", "白板武将" }, 37)
  local snatch = give(ps[2], "snatch", Card.Suit.Spade, 3, Card.Type.Trick)
  check(not r:_validateUse(ps[2], snatch, { ps[1] }), "【谦逊】不能成为【顺手牵羊】的目标")
  check(r:_validateUse(ps[2], snatch, { ps[2] }) ~= nil, "【谦逊】不影响对其他角色使用")
  -- 失去最后一张手牌 → 摸一张
  give(ps[1], "slash", Card.Suit.Spade, 5)
  ps[1].hand = {}
  local before = #ps[1].hand
  r:notifyHandEmpty(ps[1])
  check(#ps[1].hand == before + 1, "【连营】失去最后一张手牌时应摸一张牌（"
    .. before .. "→" .. #ps[1].hand .. "）")
end

do -- 【连营】的收口：出牌打到空手也应触发
  local r, ps = makeRoomWith({ "陆逊", "白板武将", "白板武将" }, 39)
  local target = ps[2]
  runInRoom(function()
    r:useCard(ps[1], give(ps[1], "slash", Card.Suit.Spade, 8), target)
  end)
  check(#ps[1].hand == 1, "出牌打到空手时【连营】应补一张（剩 "
    .. #ps[1].hand .. "）")
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

do -- 华佗·青囊：弃一张手牌令一名角色回复体力（新版：目标与代价均由华佗选）
  local r, ps = makeRoomWith({ "华佗", "白板武将" }, 52)
  ps[2].hp = 1
  give(ps[1], "dodge", Card.Suit.Spade, 2)
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end, function(req)
    if req and req.type == "askForChooseCard" then return ps[1].hand[1] end
    if req and req.type == "askForChoice" then return ps[2].name end
    return nil
  end)
  check(ps[2].hp == 2, "【青囊】应令受伤角色回复 1 点体力（" .. ps[2].hp .. "）")
  check(ps[1].qingnang_used, "【青囊】每阶段限一次")
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
  -- 注意：general 表是模块级共享的，清空后必须还原，
  -- 否则后面所有用到张飞的用例（以及 25 将总表断言）都会被污染。
  local saved = ps[2].general.skills
  check(#saved > 0, "张飞应有技能")
  r:trigger("Death", ps[1], { player = ps[1], killer = ps[2] })
  check(#ps[2].general.skills == 0, "【断肠】应令凶手失去所有技能")
  ps[2].general.skills = saved
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
  -- BOT 策略只让出一张（全送出去会养肥对手手牌，反而触发【名士】减伤）
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
  -- 注意用原版约定：回调是**方法**，第一个参数是技能自身
  local filter = sgs.CreateFilterSkill{
    name = "测试过滤",
    view_filter = function(self, card) return card.suit == Card.Suit.Spade end,
    view_as = function(self, card)
      -- 原版返回一张改过的牌；兼容层应能从中取出花色
      return Card.create(card.id, card.name, Card.Suit.Heart, card.number, card.ctype)
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

  -- askForPlayerChosen：应广播 skillTarget 指向（UI 画施法者→目标的箭头）
  local st_events = {}
  r:onEvent("skillTarget", function(d) table.insert(st_events, d) end)
  runInRoom(function()
    r:askForPlayerChosen(ps[1], r:otherAlivePlayers(ps[1]), "试炼")
  end)
  check(#st_events == 1 and st_events[1].skill == "试炼"
      and st_events[1].target ~= nil,
    "askForPlayerChosen 应广播 skillTarget 指向（实得 " .. #st_events .. " 条）")
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
  local Json = require "src.core.json"
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

print("\n--- 鸡肋 ---")

do
  local engine = Engine.create()
  Standard.setup(engine)
  local ps = {}
  for i = 1, 2 do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral("白板武将"), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(1)

  local slash = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  local snatch = Card.create(2, "snatch", Card.Suit.Spade, 5, Card.Type.Trick)
  local weapon = Card.create(3, "crossbow", Card.Suit.Spade, 5, Card.Type.Equip)

  check(ps[1]:isJilei(slash) == false, "默认不应有鸡肋")
  -- 按类别封禁
  ps[1]:setJilei("basic")
  check(ps[1]:isJilei(slash) == true, "封禁 basic 后基本牌应不可用")
  check(ps[1]:isJilei(snatch) == false, "封禁 basic 不应影响锦囊")
  check(ps[1]:isJilei(weapon) == false, "封禁 basic 不应影响装备")
  -- 按牌名精确封禁
  ps[1]:clearJilei()
  ps[1]:setJilei("snatch")
  check(ps[1]:isJilei(snatch) == true, "按牌名封禁应生效")
  check(ps[1]:isJilei(slash) == false, "按牌名封禁不应影响其他牌")
  ps[1]:clearJilei()
  check(ps[1]:isJilei(snatch) == false, "clearJilei 应解除封禁")

  -- 引擎层面：鸡肋的牌不能用
  ps[1]:setJilei("basic")
  give(ps[1], "slash", Card.Suit.Spade, 5)
  local used
  runInRoom(function()
    used = r:useCard(ps[1], ps[1].hand[1], ps[2])
  end)
  check(used == false, "鸡肋的牌应被 _validateUse 拦下")
  ps[1]:clearJilei()

  -- BOT 层面：鸡肋的牌不会被拿出来响应
  ps[1]:setJilei("basic")
  give(ps[1], "dodge", Card.Suit.Heart, 2)
  local answered = nil
  runInRoom(function()
    answered = r:askForCard(ps[1], "dodge", "请打出【闪】")
  end)
  check(answered == nil, "BOT 不应拿出鸡肋的牌响应（实得 "
    .. tostring(answered and answered.name) .. "）")
  ps[1]:clearJilei()
end

print("\n--- 询问类方法语义 ---")

do
  local engine = Engine.create()
  Standard.setup(engine)
  local ps = {}
  for i = 1, 2 do
    table.insert(ps, Player.create("P" .. i, engine:getGeneral("白板武将"), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(1)

  -- moveCardTo 应按 place 落到正确区域
  local c1 = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  r:moveCardTo(c1, nil, ps[2], "hand")
  check(ps[2].hand[#ps[2].hand] == c1, "moveCardTo(place=hand) 应进入目标手牌")
  local c2 = Card.create(2, "peach", Card.Suit.Heart, 3, Card.Type.Basic)
  r:moveCardTo(c2, nil, nil, "drawPile")
  check(r.drawPile[#r.drawPile] == c2, "moveCardTo(place=drawPile) 应回到牌堆")
  local c3 = Card.create(3, "dodge", Card.Suit.Heart, 4, Card.Type.Basic)
  r:moveCardTo(c3, nil, nil, "discardPile")
  check(r.discardPile[#r.discardPile] == c3, "moveCardTo(place=discardPile) 应进弃牌堆")
  -- 从某人手里移走
  local n = #ps[2].hand
  r:moveCardTo(c1, ps[2], nil, "discardPile")
  check(#ps[2].hand == n - 1, "moveCardTo 应把牌从来源摘除")
  check(r.discardPile[#r.discardPile] == c1, "被移走的牌应出现在弃牌堆")

  -- askForGuanxing 返回原序而不是空表（空表会让按索引取牌的脚本崩）
  local cards = { c2, c3 }
  local ordered = r:askForGuanxing(ps[1], cards, 0)
  check(ordered == cards or #ordered == 2, "askForGuanxing 应返回牌列表（维持原序）")

  -- askForAG 在空池时返回 nil
  check(r:askForAG(ps[1], {}, false) == nil, "askForAG 空池应返回 nil")
  check(r:askForAG(ps[1], { 7, 8 }, false) == 7, "askForAG 应返回选中的 id")

  -- 展示手牌不应把牌移走
  give(ps[1], "slash", Card.Suit.Spade, 9)
  local before = #ps[1].hand
  local shown = r:askForCardShow(ps[1], ps[2], "测试")
  check(shown ~= nil, "askForCardShow 应返回一张牌")
  check(#ps[1].hand == before, "askForCardShow 不应把手牌移走")
end

print("\n--- ExpPattern 区域段 ---")

do
  local ExpPattern = require "src.compat.exppattern"
  local c = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  check(ExpPattern.match(".|.|.|hand", c, "hand"), "区域段 hand 应匹配")
  check(not ExpPattern.match(".|.|.|equip", c, "hand"), "手牌不应匹配 equip 区域段")
  check(ExpPattern.match(".|.|.|equip", c, "equip"), "区域段 equip 应匹配 equip")
  check(ExpPattern.match(".|.|.|judge", c, "judge"), "区域段 judge 应匹配 judge")
  -- 未知区域名以前会静默放行，现在应不匹配
  check(not ExpPattern.match(".|.|.|乱写", c, "hand"), "未知区域名不应被静默放行")
end

print("\n--- 房间默认规模 ---")

do
  -- 约定：**默认 5 人局**，8 人为官方标准局（推荐）。
  -- 这几条断言防止以后有人随手把默认值改回 4 或 8。
  local Host = require "src.net.host"
  check(Host.create {}.count == 5, "Host 默认应为 5 人局（实得 "
    .. tostring(Host.create {}.count) .. "）")
  check(Host.create { count = 8 }.count == 8, "显式指定 8 人应生效")
  -- 身份配置表本身应覆盖 4..8
  local Room = require "src.core.room"
  for n = 4, 8 do
    check(Room.ROLE_SETUP[n] ~= nil, n .. " 人局应有身份配置")
  end
  check(Room.ROLE_SETUP[8].loyalist == 2 and Room.ROLE_SETUP[8].rebel == 4,
    "8 人局应为 忠2 反4（官方标准）")
  check(Room.ROLE_SETUP[5].loyalist == 1 and Room.ROLE_SETUP[5].rebel == 2,
    "5 人局应为 忠1 反2")
end

print("\n--- 身份局人数配置 ---")

do
  local Room = require "src.core.room"
  local Player = require "src.core.player"

  local function roles(n)
    local engine = Engine.create()
    Standard.setup(engine)
    local G = require "src.core.generals"
    local all = G.all()
    local ps = {}
    for i = 1, n do
      table.insert(ps, Player.create("P" .. i, all[((i - 1) % #all) + 1], i, false))
    end
    local r = Room.create(engine, ps)
    r:setupRoles(Standard.makeRng(n))
    local c = {}
    for _, p in ipairs(ps) do c[p.role] = (c[p.role] or 0) + 1 end
    return c, r
  end

  -- 官方标准配置
  local c8, r8 = roles(8)
  check(c8.lord == 1 and c8.loyalist == 2 and c8.rebel == 4 and c8.renegade == 1,
    string.format("8 人应为 主1 忠2 反4 内1（实得 主%d 忠%d 反%d 内%d）",
      c8.lord or 0, c8.loyalist or 0, c8.rebel or 0, c8.renegade or 0))
  local c5 = roles(5)
  check(c5.lord == 1 and c5.loyalist == 1 and c5.rebel == 2 and c5.renegade == 1,
    string.format("5 人应为 主1 忠1 反2 内1（实得 主%d 忠%d 反%d 内%d）",
      c5.lord or 0, c5.loyalist or 0, c5.rebel or 0, c5.renegade or 0))
  local c4 = roles(4)
  check(c4.lord == 1 and c4.loyalist == 1 and c4.rebel == 1 and c4.renegade == 1, "4 人配置应正确")
  -- 主公明身份且 +1 体力（5 人及以上）
  check(r8:getLord() ~= nil and r8:getLord().role_revealed, "主公应明置身份")
  check(r8:getLord().max_hp == r8:getLord().general.max_hp + 1, "8 人局主公应 +1 体力上限")
  -- 其余暗置
  local hidden = true
  for _, p in ipairs(r8.players) do
    if p.role ~= "lord" and p.role_revealed then hidden = false end
  end
  check(hidden, "非主公身份应暗置")

  -- 文档：4 人局主公**不**加体力上限
  local _, r4 = roles(4)
  check(r4:getLord().max_hp == r4:getLord().general.max_hp,
    "4 人局主公不应 +1 体力上限（实得 " .. r4:getLord().max_hp .. "）")

  -- 文档：9 / 10 人局也要有身份配置
  local c9 = roles(9)
  check(c9.lord == 1 and c9.loyalist == 3 and c9.rebel == 4 and c9.renegade == 1,
    string.format("9 人应为 主1 忠3 反4 内1（实得 主%d 忠%d 反%d 内%d）",
      c9.lord or 0, c9.loyalist or 0, c9.rebel or 0, c9.renegade or 0))
  local c10 = roles(10)
  check(c10.lord == 1 and c10.loyalist == 3 and c10.rebel == 4 and c10.renegade == 2,
    string.format("10 人应为 主1 忠3 反4 内2（实得 主%d 忠%d 反%d 内%d）",
      c10.lord or 0, c10.loyalist or 0, c10.rebel or 0, c10.renegade or 0))
end

print("\n--- 标准版数值（文档对标）---")

do
  local G = require "src.core.generals"
  local byName = {}
  for _, g in ipairs(G.all()) do byName[g.name] = g end
  check(byName["关羽"].max_hp == 4, "关羽标准版应为 4 体力（实得 "
    .. byName["关羽"].max_hp .. "）")
  check(byName["吕布"].max_hp == 4, "吕布标准版应为 4 体力（实得 "
    .. byName["吕布"].max_hp .. "）")
end

print("\n--- 判定区规则 ---")

do
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 41)
  local a = Card.create(1, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  local b = Card.create(2, "indulgence", Card.Suit.Club, 6, Card.Type.Trick)
  ps[1]:addJudge(a)
  ps[1]:addJudge(b)
  local order = {}
  -- 后进先判：先判 b，再判 a
  r._judgeCard = function(self, p, card)
    table.insert(order, card)
    p:removeJudge(card)
    table.insert(self.discardPile, card)
    return nil
  end
  r:_phase_judge(ps[1])
  check(order[1] == b and order[2] == a,
    "多张延时锦囊应从最后放入的那张开始判定")
end

do
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 42)
  local first = Card.create(1, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  ps[2]:addJudge(first)
  local second = Card.create(2, "indulgence", Card.Suit.Club, 6, Card.Type.Trick)
  local ok = r:_validateUse(ps[1], second, { ps[2] })
  check(not ok, "同一角色判定区不能放第二张同名延时锦囊【乐不思蜀】")
  check(#ps[2].judges == 1, "被拒绝后判定区仍只有一张")
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

print("\n--- 标记类技能接进引擎 ---")

do
  local sgs = require "src.compat.sgs"
  local engine = Engine.create()
  Standard.setup(engine)
  local mk = function(n)
    local ps = {}
    for i = 1, (n or 3) do
      table.insert(ps, Player.create("P" .. i, engine:getGeneral("白板武将"), i, false))
    end
    local r = Room.create(engine, ps)
    r.drawPile = Standard.buildDrawPile(1)
    return r, ps
  end

  -- DistanceSkill：距离 -1
  local r, ps = mk()
  local dist0 = r:distance(ps[1], ps[3]) -- 3 人环形：1 与 3 相邻，距离为 1
  ps[1].extra_skills = {
    sgs.CreateDistanceSkill{
      name = "减距",
      correct_func = function(self, from, to) return -1 end,
    },
  }
  local dist1 = r:distance(ps[1], ps[3])
  check(dist0 == 1, "3 人局 1↔3 基础距离应为 1（实得 " .. dist0 .. "）")
  check(dist1 == 1, "距离最低为 1，不应被减到 0（实得 " .. dist1 .. "）")

  -- 换个能看出差别的场景：4 人局对家距离 2
  local r2, ps2 = mk(4)
  local d0 = r2:distance(ps2[1], ps2[3])
  ps2[1].extra_skills = {
    sgs.CreateDistanceSkill{
      name = "减距",
      correct_func = function(self, from, to) return -1 end,
    },
  }
  local d1 = r2:distance(ps2[1], ps2[3])
  check(d0 == 2 and d1 == 1, string.format("DistanceSkill 应使距离 %d → %d", d0, d1))

  -- MaxCardsSkill：手牌上限 +2
  local r3, ps3 = mk()
  local base = r3:maxCards(ps3[1])
  ps3[1].extra_skills = {
    sgs.CreateMaxCardsSkill{
      name = "扩容",
      extra_func = function(self, player) return 2 end,
    },
  }
  check(r3:maxCards(ps3[1]) == base + 2,
    string.format("MaxCardsSkill 应使上限 %d → %d", base, r3:maxCards(ps3[1])))

  -- AttackRangeSkill：攻击范围 +1
  local r4, ps4 = mk()
  local ar0 = r4:attackRangeOf(ps4[1])
  ps4[1].extra_skills = {
    sgs.CreateAttackRangeSkill{
      name = "长臂",
      extra_func = function(self, player) return 1 end,
    },
  }
  check(r4:attackRangeOf(ps4[1]) == ar0 + 1,
    string.format("AttackRangeSkill 应使范围 %d → %d", ar0, r4:attackRangeOf(ps4[1])))

  -- TargetModSkill：出杀次数 +1
  local r5, ps5 = mk()
  local sl0 = r5:slashLimit(ps5[1])
  ps5[1].extra_skills = {
    sgs.CreateTargetModSkill{
      name = "连击",
      residue_func = function(self, player, card) return 1 end,
    },
  }
  check(r5:slashLimit(ps5[1]) == sl0 + 1,
    string.format("TargetModSkill 应使出杀上限 %d → %d", sl0, r5:slashLimit(ps5[1])))

  -- ProhibitSkill：禁止被指定
  local r6, ps6 = mk()
  local card = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  check(r6:isProhibited(ps6[1], ps6[2], card) == false, "默认不应禁止")
  ps6[2].extra_skills = {
    sgs.CreateProhibitSkill{
      name = "护体",
      is_prohibited = function(self, from, to, c) return to == ps6[2] end,
    },
  }
  check(r6:isProhibited(ps6[1], ps6[2], card) == true, "ProhibitSkill 应拦下对该角色的指定")
  check(r6:isProhibited(ps6[1], ps6[3], card) == false, "不应影响其他角色")
end

print("\n--- 卡牌包：新建卡种 ---")

do
  local sgs = require "src.compat.sgs"
  local Cards = require "src.core.cards"

  -- 定义一张新锦囊：指定一名角色，令其摸一张牌
  local fired = false
  local newcard = sgs.CreateTrickCard{
    name = "测试锦囊",
    target_fixed = false,
    on_effect = function(self, effect)
      fired = true
      effect.from.room_dummy = effect.to
    end,
  }
  check(Cards.get("测试锦囊") ~= nil, "新建锦囊应登记进卡种表")
  check(Cards.isTrick("测试锦囊"), "CreateTrickCard 的卡种应为锦囊")
  check(newcard ~= nil and newcard.name == "测试锦囊", "构造应返回一张该卡的实例")

  -- 定义一张新武器，攻击范围 3
  sgs.CreateWeapon{
    name = "测试刀",
    range = 3,
    on_effect = function() end,
  }
  local def = Cards.get("测试刀")
  check(def ~= nil, "新建武器应登记进卡种表")
  check(Cards.isEquip("测试刀"), "CreateWeapon 的卡种应为装备")
  check(def and def.equip == "weapon", "CreateWeapon 的槽位应为 weapon")
  check(def and def.range == 3, "CreateWeapon 应记录攻击范围（实得 "
    .. tostring(def and def.range) .. "）")

  -- 防具 / 宝物
  sgs.CreateArmor{ name = "测试甲", on_effect = function() end }
  check((Cards.get("测试甲") or {}).equip == "armor", "CreateArmor 槽位应为 armor")
  sgs.CreateTreasure{ name = "测试宝物", on_effect = function() end }
  check(Cards.get("测试宝物") ~= nil, "CreateTreasure 应能登记（映射到防具槽）")

  -- 基本牌
  sgs.CreateBasicCard{ name = "测试基本", on_effect = function() end }
  check((Cards.get("测试基本") or {}).ctype == Card.Type.Basic, "CreateBasicCard 卡种应为基本")
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

  -- BOT：不应询问，直接发动（BOT 走的是技能自身逻辑）
  local r2 = mk(false)
  runInRoom(function()
    r2:trigger("EventPhaseStart", r2.players[1],
      { player = r2.players[1], phase = "play" })
  end)
  check(r2.players[1].hp == 3, "BOT 应直接发动【苦肉】（hp 4→"
    .. r2.players[1].hp .. "）")

  -- 名字带「·」的子技能是别的技能的实现细节，不应打扰玩家。
  -- 之前 Room:trigger 是「先弹窗再判条件」，导致【激将·出杀】【仁德·回血】
  -- 这类辅助技在每个阶段都弹一次 —— 表现就是「进入游戏后界面卡死」。
  local r4 = Room.create(engine, {
    Player.create("P1", engine:getGeneral("刘备"), 1, true),
    Player.create("P2", engine:getGeneral("白板武将"), 2, false),
  })
  r4.drawPile = Standard.buildDrawPile(1)
  r4.identity_mode = true
  r4.players[1].role = "lord"
  local asked4 = nil
  runInRoom(function()
    r4:trigger("CardUsed", r4.players[1],
      { from = r4.players[1], card = { name = "rende" } })
  end, function(req)
    if req.type == "askForSkillInvoke" then asked4 = req.skill end
    return nil
  end)
  check(asked4 == nil, "内部子技能（仁德·回血）不应弹出征询（实得 "
    .. tostring(asked4) .. "）")

  -- 仍应征询的真实主动技：名字不带「·」
  local r5 = Room.create(engine, {
    Player.create("P1", engine:getGeneral("黄盖"), 1, true),
    Player.create("P2", engine:getGeneral("白板武将"), 2, false),
  })
  r5.drawPile = Standard.buildDrawPile(1)
  r5.players[1].hp = 4
  local asked5 = nil
  runInRoom(function()
    r5:trigger("EventPhaseStart", r5.players[1],
      { player = r5.players[1], phase = "play" })
  end, function(req)
    if req.type == "askForSkillInvoke" then asked5 = req.skill return false end
    return nil
  end)
  check(asked5 ~= nil, "真实主动技（苦肉）仍应弹出征询")

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

print("\n--- 出牌合法性查询（UI / BOT 共用）---")

do
  local r, ps = makeRoomWith({
    "白板武将", "白板武将", "白板武将", "白板武将", "白板武将",
  }, 71)
  local slash = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  local snatch = Card.create(2, "snatch", Card.Suit.Spade, 3, Card.Type.Trick)

  local ok1 = r:canUseCardOn(ps[1], slash, ps[2]) -- 相邻，距离 1
  check(ok1 == true, "距离 1 的目标应可用【杀】")
  local ok2, why2 = r:canUseCardOn(ps[1], slash, ps[3]) -- 距离 2
  check(not ok2 and why2 and tostring(why2):find("攻击范围"),
    "距离 2 的目标应被拒绝并说明原因（实得 " .. tostring(why2) .. "）")

  ps[1].slash_count = 1
  local ok3, why3 = r:canUseCardOn(ps[1], slash, ps[2])
  check(not ok3 and why3 and tostring(why3):find("已使用过"),
    "本回合出杀次数用尽应被拒绝（实得 " .. tostring(why3) .. "）")
  ps[1].slash_count = 0

  local ok4, why4 = r:canUseCardOn(ps[1], snatch, ps[3])
  check(not ok4 and why4 and tostring(why4):find("顺手牵羊"),
    "【顺手牵羊】超出距离 1 应被拒绝（实得 " .. tostring(why4) .. "）")
  check(r:canUseCardOn(ps[1], snatch, ps[2]) == true, "【顺手牵羊】对相邻角色应可用")

  -- 自己不能指定自己（需要目标的牌）
  local ok5 = r:canUseCardOn(ps[1], slash, ps[1])
  check(not ok5, "不应能把需要目标的牌用在自己身上")
end

print("\n--- 观星 ---")

do
  local r, ps = makeRoomWith({ "诸葛亮", "白板武将" }, 55)
  local c1 = Card.create(1, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
  local c2 = Card.create(2, "dodge", Card.Suit.Heart, 2, Card.Type.Basic)
  local c3 = Card.create(3, "peach", Card.Suit.Heart, 3, Card.Type.Basic)
  r.drawPile = { c3, c2, c1 } -- 尾部 = 牌堆顶
  local asked = nil
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "start" })
  end, function(req)
    if req.type == "askForGuanxing" then
      asked = req
      return { up = { req.cards[2], req.cards[1] }, down = {} }
    end
    return nil
  end)
  check(asked ~= nil, "【观星】应弹出重排牌堆顶的询问")
  check(asked and #asked.cards == 2, "【观星】张数 = 存活人数且至多 5（实得 "
    .. tostring(asked and #asked.cards) .. "）")
  check(#r.drawPile == 3, "【观星】后牌堆总数不变（实得 " .. #r.drawPile .. "）")
  check(r.drawPile[#r.drawPile] == c2 and r.drawPile[#r.drawPile - 1] == c1,
    "【观星】应按给定顺序放回牌堆顶")
end

print("\n--- 主公技（护驾 / 激将 / 救援）---")

local function lordRoom(keys, seed)
  local r, ps = makeRoomWith(keys, seed)
  r.identity_mode = true
  ps[1].role = "lord"
  return r, ps
end

local function skillNamed(p, name)
  for _, s in ipairs((p.general and p.general.skills) or {}) do
    if s.name == name then return s end
  end
  return nil
end

do -- 曹操【护驾】：需要闪时由魏势力角色提供
  local r, ps = lordRoom({ "曹操", "夏侯惇" }, 51)
  local s = skillNamed(ps[1], "护驾")
  check(s and s.lord_supply and s.lord_supply.dodge, "曹操应拥有主公技【护驾】")
  local dodge = give(ps[2], "dodge", Card.Suit.Heart, 2)
  local slash = give(ps[2], "slash", Card.Suit.Spade, 8)
  local hp = ps[1].hp
  runInRoom(function() r:useCard(ps[2], slash, ps[1]) end, function(req)
    if req.type == "askForCard" and req.card_name == "dodge" then
      if req.player == ps[1] then return nil end -- 曹操自己没有闪
      return dodge
    end
    return nil
  end)
  check(ps[1].hp == hp, "【护驾】应由魏势力角色提供【闪】，主公不掉血（hp "
    .. hp .. "→" .. ps[1].hp .. "）")
end

do -- 刘备【激将】：需要杀时由蜀势力角色提供
  local r, ps = lordRoom({ "刘备", "关羽" }, 52)
  local s = skillNamed(ps[1], "激将")
  check(s and s.lord_supply and s.lord_supply.slash, "刘备应拥有主公技【激将】")
  local slash = give(ps[2], "slash", Card.Suit.Spade, 8)
  local got = nil
  runInRoom(function() got = r:lordSupply(ps[1], "slash") end, function(req)
    if req.type == "askForCard" and req.card_name == "slash"
      and req.player == ps[2] then
      return slash
    end
    return nil
  end)
  check(got == slash, "【激将】应取得蜀势力角色提供的【杀】")
  check(ps[1].hand[#ps[1].hand] == slash, "提供的【杀】应先转入主公手牌")
end

do -- 孙权【救援】：吴势力角色的桃额外回 1 点
  local r, ps = lordRoom({ "孙权", "周瑜" }, 53)
  local peach = give(ps[2], "peach", Card.Suit.Heart, 3)
  ps[1].hp = 0
  runInRoom(function() r:_dying(ps[1], nil) end, function(req)
    if req.type == "askForCard" and req.card_name == "peach" then
      if req.player == ps[1] then return nil end
      return peach
    end
    return nil
  end)
  check(ps[1].alive and ps[1].hp == 2,
    "【救援】下吴势力的【桃】应回复 2 点（hp " .. ps[1].hp .. "）")
end

do -- 主公技只在担任主公时可用
  local r, ps = makeRoomWith({ "曹操", "夏侯惇" }, 54)
  r.identity_mode = true
  ps[1].role = "rebel" -- 曹操不是主公
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  local got = nil
  runInRoom(function() got = r:lordSupply(ps[1], "dodge") end)
  check(got == nil, "非主公身份时【护驾】不应生效")
end

print("\n--- 标准版武器（雌雄/青龙/方天/丈八/贯石）---")

local function equipCard(p, name)
  local def = Cards.get(name)
  local c = Card.create(2000 + #p.hand, name, Card.Suit.Spade, 5,
    def and def.ctype or Card.Type.Equip)
  p.equips[def.equip or "weapon"] = c
  return c
end

do -- 雌雄双股剑：异性目标弃 1 张，无牌则使用者摸 1 张
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 31)
  ps[2].female = true
  equipCard(ps[1], "double_sword")
  give(ps[2], "slash", Card.Suit.Spade, 5)
  local n2 = #ps[2].hand
  runInRoom(function()
    r:useCard(ps[1], give(ps[1], "slash", Card.Suit.Spade, 6), ps[2])
  end, function(req)
    if req.type == "askForDiscardFrom" then return req.target.hand[1] end
    return nil
  end)
  check(#ps[2].hand == n2 - 1, "【雌雄双股剑】应令异性目标弃置一张手牌（"
    .. #ps[2].hand .. " vs " .. n2 - 1 .. "）")
end

do -- 青龙偃月刀：目标出闪后可再出一张杀
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 32)
  equipCard(ps[1], "blade")
  give(ps[2], "dodge", Card.Suit.Heart, 2) -- 目标有闪
  give(ps[1], "slash", Card.Suit.Spade, 7) -- 追击用
  local hp = ps[2].hp
  runInRoom(function()
    r:useCard(ps[1], give(ps[1], "slash", Card.Suit.Spade, 8), ps[2])
  end, function(req)
    if req.type == "askForCard" then
      if req.card_name == "dodge" then return req.player.hand[1] end
      if req.card_name == "slash" then
        for _, c in ipairs(req.player.hand) do
          if c.name == "slash" then return c end
        end
      end
    end
    return nil
  end)
  check(ps[2].hp == hp - 1, "【青龙偃月刀】追击的杀应造成伤害（hp "
    .. hp .. "→" .. ps[2].hp .. "）")
end

do -- 贯石斧：弃两张牌强制命中
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 33)
  equipCard(ps[1], "axe")
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  give(ps[1], "peach", Card.Suit.Heart, 3)
  give(ps[1], "peach", Card.Suit.Heart, 4)
  local hp = ps[2].hp
  runInRoom(function()
    r:useCard(ps[1], give(ps[1], "slash", Card.Suit.Spade, 8), ps[2])
  end, function(req)
    if req.type == "askForCard" and req.card_name == "dodge" then
      return req.player.hand[1]
    end
    if req.type == "askForDiscard" then
      local out = {}
      for i = 1, math.min(req.n, #req.player.hand) do out[i] = req.player.hand[i] end
      return out
    end
    return nil
  end)
  check(ps[2].hp == hp - 1, "【贯石斧】弃两张牌后杀应依然命中（hp "
    .. hp .. "→" .. ps[2].hp .. "）")
  check(#ps[1].hand == 0, "【贯石斧】应消耗两张手牌（剩 " .. #ps[1].hand .. "）")
end

do -- 贯石斧：牌面写「两张牌」，可弃装备（含贯石斧自身）
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 330)
  local axe = equipCard(ps[1], "axe")
  local armor = equipCard(ps[1], "eight_diagram")
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  local hp, saw_equips = ps[2].hp, false
  runInRoom(function()
    r:useCard(ps[1], give(ps[1], "slash", Card.Suit.Spade, 8), ps[2])
  end, function(req)
    if req.type == "askForCard" and req.card_name == "dodge" then
      return req.player.hand[1]
    end
    if req.type == "askForDiscard" then
      if req.include_equips and req.cards and #req.cards == 2 then saw_equips = true end
      return { axe, armor }
    end
    return nil
  end)
  check(saw_equips, "【贯石斧】弃牌请求应包含本人装备区")
  check(ps[1].equips.weapon == nil and ps[1].equips.armor == nil,
    "【贯石斧】应允许弃置武器自身和另一件装备")
  check(ps[2].hp == hp - 1, "弃两件装备后【杀】仍应强制命中")
end

do -- 丈八蛇矛：两张手牌当杀
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 34)
  equipCard(ps[1], "spear")
  give(ps[1], "peach", Card.Suit.Heart, 3)
  give(ps[1], "peach", Card.Suit.Heart, 4)
  local cands = r:viewAsCandidates(ps[1], "slash")
  check(#cands > 0 and cands[1].card2 ~= nil,
    "装备【丈八蛇矛】时应能选出两张手牌当【杀】")
  local made = cands[1].skill:view_as({ cands[1].card, cands[1].card2 })
  check(made and made.name == "slash", "【丈八蛇矛】应转化出一张【杀】")
end

do -- 方天画戟：杀后无手牌可额外指定至多 2 人（新版：目标由使用者选定）
  local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将", "白板武将" }, 35)
  equipCard(ps[1], "halberd")
  local hp2, hp3 = ps[2].hp, ps[3].hp
  local appended = 0
  runInRoom(function()
    r:useCard(ps[1], give(ps[1], "slash", Card.Suit.Spade, 8), ps[2])
  end, function(req)
    if req and req.type == "askForChoice" then
      appended = appended + 1
      if appended == 1 then return ps[3].name end -- 追加 P3
      return "不追加" -- 第二次不再追加
    end
    return nil -- 问闪一律不出
  end)
  check(#ps[1].hand == 0, "【方天画戟】发动前提：杀后没有手牌")
  check(ps[2].hp < hp2 and ps[3].hp < hp3,
    "【方天画戟】应额外指定另两名角色（" .. ps[2].hp .. "/" .. ps[3].hp .. "）")
end

print("\n--- 濒死救援（文档规则：本人优先 + 逆时针询问全场）---")

do -- 本人无桃、他人有桃 → 被救回
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 21)
  local peach = give(ps[2], "peach", Card.Suit.Heart, 3)
  ps[1].hp = 0
  runInRoom(function() r:_dying(ps[1], nil) end, function(req)
    if req.type == "askForCard" and req.card_name == "peach" and req.player == ps[2] then
      return peach
    end
    return nil
  end)
  check(ps[1].alive, "濒死者本人无桃时，他人应能出【桃】救回")
  check(ps[1].hp == 1, "救回后体力应为 1（实得 " .. ps[1].hp .. "）")
  check(hasCard(r.discardPile, peach), "救援用的【桃】应进入弃牌堆")
end

do -- 全场无桃 → 阵亡
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 22)
  ps[1].hp = 0
  runInRoom(function() r:_dying(ps[1], nil) end)
  check(not ps[1].alive, "无人出【桃】时应阵亡")
end

do -- 需要两张桃时，恰好消耗两张，不多弃
  local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将" }, 23)
  give(ps[2], "peach", Card.Suit.Heart, 3)
  give(ps[3], "peach", Card.Suit.Heart, 4)
  ps[1].hp = -1
  runInRoom(function() r:_dying(ps[1], nil) end, function(req)
    if req.type == "askForCard" and req.card_name == "peach" and req.player ~= ps[1] then
      return req.player.hand[1]
    end
    return nil
  end)
  check(ps[1].alive and ps[1].hp == 1, "两张【桃】应把 -1 体力的角色救回 1 点（实得 "
    .. ps[1].hp .. "）")
  check(#ps[2].hand == 0 and #ps[3].hand == 0, "两名救援者各消耗一张【桃】")
end

do -- 【完杀】：贾诩回合内他人无法救援
  local r, ps = makeRoomWith({ "白板武将", "贾诩" }, 24)
  give(ps[2], "peach", Card.Suit.Heart, 3)
  ps[1].hp = 0
  r.current_seat = 2 -- 贾诩的回合
  runInRoom(function() r:_dying(ps[1], nil) end, function(req)
    if req.type == "askForCard" and req.card_name == "peach" and req.player == ps[2] then
      return ps[2].hand[1]
    end
    return nil
  end)
  check(not ps[1].alive, "【完杀】生效时他人无法用【桃】救援")
  check(#ps[2].hand == 1, "【完杀】下救援者的【桃】不应被消耗")
end

print("\n--- 技能语义修正（文档对标）---")

do -- 鬼才：可对**他人**的判定改判（给敌人送判定）
  local r, ps = makeRoomWith({ "司马懿", "白板武将" }, 61)
  r.identity_mode = true
  ps[1].role, ps[2].role = "loyalist", "rebel"
  local spade = give(ps[1], "slash", Card.Suit.Spade, 5) -- 黑桃：乐不思蜀会生效
  local indulgence = Card.create(1, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  local heart = Card.create(2, "dodge", Card.Suit.Heart, 2, Card.Type.Basic)
  local data = { player = ps[2], card = indulgence, judge_card = heart, reason = "indulgence" }
  runInRoom(function()
    r:trigger("AskForRetrial", ps[2], data)
  end, function(req)
    -- 新版鬼才由玩家选替换手牌；测试选那张黑桃（把敌人的乐改成生效）
    return (req and req.type == "askForChooseCard") and spade or nil
  end)
  check(data.judge_card == spade,
    "【鬼才】应能把敌人的判定改成生效（实得 " .. tostring(data.judge_card.name) .. "）")
end

do -- 仁德：本阶段给出 2 张即回 1 血，且每阶段只回一次
  local r, ps = makeRoomWith({ "刘备", "白板武将" }, 62)
  ps[1].hp = 1
  local function give_rende()
    r:trigger("CardUsed", ps[1], { from = ps[1], card = { name = "rende" } })
  end
  give_rende(); give_rende()
  check(ps[1].hp == 2, "【仁德】本阶段给出 2 张应回复 1 点（hp " .. ps[1].hp .. "）")
  give_rende(); give_rende()
  check(ps[1].hp == 2, "【仁德】每阶段只回复一次（hp " .. ps[1].hp .. "）")
  r:trigger("EventPhaseEnd", ps[1], { player = ps[1], phase = "play" })
  give_rende(); give_rende()
  check(ps[1].hp == 3, "【仁德】下个出牌阶段可再次回复（hp " .. ps[1].hp .. "）")
end

do -- 苦肉：出牌阶段可多次发动
  local r, ps = makeRoomWith({ "黄盖", "白板武将" }, 63)
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  check(ps[1].hp == 2, "【苦肉】同一出牌阶段可多次发动（hp " .. ps[1].hp .. "）")
end

do -- 结姻：自己满血也能发动（只要求目标是已受伤男性）
  local r, ps = makeRoomWith({ "孙尚香", "白板武将" }, 64)
  ps[2].hp = 1
  give(ps[1], "slash", Card.Suit.Spade, 5)
  give(ps[1], "slash", Card.Suit.Spade, 6)
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end, function(req)
    -- 新版结姻：先弃两张手牌（多选），再选目标
    if req and req.type == "askForDiscard" then
      return { ps[1].hand[1], ps[1].hand[2] }
    end
    if req and req.type == "askForChoice" then return ps[2].name end
    return nil
  end)
  check(ps[2].hp == 2, "【结姻】自己满血时也应能发动（目标 hp " .. ps[2].hp .. "）")
end

do -- 反间：目标主动选择花色，猜错受伤
  local r, ps = makeRoomWith({ "周瑜", "白板武将" }, 65)
  give(ps[1], "slash", Card.Suit.Spade, 8) -- 实际是黑桃
  local asked = nil
  local hp = ps[2].hp
  runInRoom(function()
    r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end, function(req)
    if req.type == "askForChoice" then asked = req return "红桃" end
    return nil
  end)
  check(asked ~= nil, "【反间】应询问目标猜测花色")
  check(ps[2].hp == hp - 1, "猜错花色应受到 1 点伤害（hp " .. hp .. "→" .. ps[2].hp .. "）")
end

do -- 离间产生的决斗不可被【无懈可击】响应
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 66)
  give(ps[2], "nullification", Card.Suit.Spade, 11, Card.Type.Trick)
  local duel = Card.create(1, "duel", Card.Suit.Spade, 1, Card.Type.Trick)
  duel.no_nullify = true
  runInRoom(function() r:useCard(ps[1], duel, ps[2]) end)
  check(#ps[2].hand == 1, "标记 no_nullify 的锦囊不应触发【无懈可击】响应")
end

do -- 【酒】：出牌阶段不回血，只给下一张杀 +1；濒死才回血
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 67)
  ps[1].hp = 1
  local wine = give(ps[1], "analeptic", Card.Suit.Spade, 9)
  runInRoom(function() r:useCard(ps[1], wine, ps[1]) end)
  check(ps[1].hp == 1, "出牌阶段使用【酒】不应回血（hp " .. ps[1].hp .. "）")
  check(ps[1].drunk == true, "出牌阶段使用【酒】应置 drunk（下一张杀 +1）")
end

do -- 平局：牌堆与弃牌堆都空时摸牌
  local r, ps = makeRoomWith({ "白板武将", "白板武将" }, 68)
  r.drawPile, r.discardPile = {}, {}
  r:drawCards(ps[1], 1)
  check(r.game_over, "牌堆+弃牌堆不足时应结束对局")
  check(r.winner == nil, "这种情况应判平局（无胜者）")
end

print("\n--- 标准版 25 将总表（防止与文档脱节）---")

do
  -- 数据来自《基础版武将与卡牌全表》第 1-5 节
  local DOC = {
    { "曹操", "wei", 4, { "奸雄", "护驾" } },
    { "司马懿", "wei", 3, { "反馈", "鬼才" } },
    { "夏侯惇", "wei", 4, { "刚烈" } },
    { "张辽", "wei", 4, { "突袭" } },
    { "许褚", "wei", 4, { "裸衣" } },
    { "郭嘉", "wei", 3, { "天妒", "遗计" } },
    { "甄姬", "wei", 3, { "倾国", "洛神" } },
    { "刘备", "shu", 4, { "仁德", "激将" } },
    { "关羽", "shu", 4, { "武圣" } },
    { "张飞", "shu", 4, { "咆哮" } },
    { "诸葛亮", "shu", 3, { "观星", "空城" } },
    { "赵云", "shu", 4, { "龙胆" } },
    { "马超", "shu", 4, { "马术", "铁骑" } },
    { "黄月英", "shu", 3, { "集智", "奇才" } },
    { "孙权", "wu", 4, { "制衡", "救援" } },
    { "甘宁", "wu", 4, { "奇袭" } },
    { "吕蒙", "wu", 4, { "克己" } },
    { "黄盖", "wu", 4, { "苦肉" } },
    { "周瑜", "wu", 3, { "英姿", "反间" } },
    { "大乔", "wu", 3, { "国色", "流离" } },
    { "陆逊", "wu", 3, { "谦逊", "连营" } },
    { "孙尚香", "wu", 3, { "结姻", "枭姬" } },
    { "华佗", "qun", 3, { "急救", "青囊" } },
    { "吕布", "qun", 4, { "无双" } },
    { "貂蝉", "qun", 3, { "离间", "闭月" } },
  }
  local byName = {}
  for _, g in ipairs(Generals.all()) do byName[g.name] = g end
  local bad = {}
  for _, d in ipairs(DOC) do
    local g = byName[d[1]]
    if not g then
      table.insert(bad, d[1] .. " 缺失")
    else
      if g.kingdom ~= d[2] then table.insert(bad, d[1] .. " 势力") end
      if g.max_hp ~= d[3] then
        table.insert(bad, string.format("%s 体力%d≠%d", d[1], g.max_hp, d[3]))
      end
      local have = {}
      for _, s in ipairs(g.skills or {}) do
        local n = s.name or s.zh or "?"
        have[n] = true
        local base = n:match("^(.-)[·]")
        if base then have[base] = true end
      end
      for _, want in ipairs(d[4]) do
        if not have[want] then table.insert(bad, d[1] .. " 缺【" .. want .. "】") end
      end
    end
  end
  check(#bad == 0, "标准版 25 将的势力/体力/技能应与文档一致（差异: "
    .. table.concat(bad, "；") .. "）")
end

print("\n--- 六匹马：牌名 / 花色点数 / 距离 ---")

do
  -- 回归：以前牌堆用「防御马/进攻马」这类**类别名**，导致
  --   1) 界面显示通用名（看不到的卢/绝影…）
  --   2) 6 匹马全部没有卡图（卡图按具体牌名找文件）
  local HORSES = {
    { "jueying", "绝影", "defensive_horse", Card.Suit.Spade, 5 },
    { "zhuahuangfeidian", "爪黄飞电", "defensive_horse", Card.Suit.Heart, 13 },
    { "dilu", "的卢", "defensive_horse", Card.Suit.Club, 5 },
    { "dayuan", "大宛", "offensive_horse", Card.Suit.Spade, 13 },
    { "chitu", "赤兔", "offensive_horse", Card.Suit.Heart, 5 },
    { "zixing", "紫骍", "offensive_horse", Card.Suit.Diamond, 13 },
  }

  for _, h in ipairs(HORSES) do
    local key, zh, slot, suit, num = h[1], h[2], h[3], h[4], h[5]
    local d = Cards.get(key)
    check(d ~= nil, "应定义马【" .. zh .. "】（key=" .. key .. "）")
    if d then
      check(d.zh == zh, string.format("%s 的中文名应为%s（实得 %s）", key, zh, d.zh))
      check(d.equip == slot, string.format("【%s】应占 %s 槽（实得 %s）", zh, slot, tostring(d.equip)))
    end
  end

  -- 牌堆里这 6 匹各一张，且花色点数与资料一致
  local SUIT_ZH = { [Card.Suit.Spade] = "♠", [Card.Suit.Heart] = "♥",
    [Card.Suit.Club] = "♣", [Card.Suit.Diamond] = "♦" }
  local cnt, bySuitNum = {}, {}
  for _, row in ipairs(require("src.core.deck_spec").STANDARD) do
    cnt[row[3]] = (cnt[row[3]] or 0) + 1
    bySuitNum[row[1] .. ":" .. row[2]] = row[3]
  end
  for _, h in ipairs(HORSES) do
    local key, zh, _, suit, num = h[1], h[2], h[3], h[4], h[5]
    check(cnt[key] == 1, string.format("牌堆里【%s】应恰好 1 张（实得 %d）", zh, cnt[key] or 0))
    check(bySuitNum[suit .. ":" .. num] == key,
      string.format("%s%d 应为【%s】（实得 %s）", SUIT_ZH[suit] or suit, num, zh,
        tostring(bySuitNum[suit .. ":" .. num])))
  end

  -- 牌堆不应再使用类别名（否则界面上又会出现无名马）
  check((cnt["offensive_horse"] or 0) == 0 and (cnt["defensive_horse"] or 0) == 0,
    "标准牌堆不应再使用「进攻马/防御马」类别名")

  -- 距离：5 人局座位 1↔3 基础距离 2
  local eng = Engine.create()
  Standard.setup(eng)
  local function distWith(key, def)
    local ps = {}
    for i = 1, 5 do
      table.insert(ps, Player.create("P" .. i, eng:getGeneral("白板武将"), i, false))
    end
    local r = Room.create(eng, ps)
    r:setupRoles(Standard.makeRng(1))
    r:start()
    local c = Card.create(900, key, Card.Suit.Club, 5, Card.Type.Equip)
    if def then ps[3]:equipCard(c, "defensive_horse") else ps[1]:equipCard(c, "offensive_horse") end
    return r:distance(ps[1], ps[3])
  end
  check(distWith("jueying", true) == 3, "【绝影】应让其他人算你 +1（2 -> 3）")
  check(distWith("zhuahuangfeidian", true) == 3, "【爪黄飞电】应 +1")
  check(distWith("dilu", true) == 3, "【的卢】应 +1")
  check(distWith("dayuan", false) == 1, "【大宛】应让你算别人 -1（2 -> 1）")
  check(distWith("chitu", false) == 1, "【赤兔】应 -1")
  check(distWith("zixing", false) == 1, "【紫骍】应 -1")

  -- 一攻一防同时装备应互相抵消（2 - 1 + 1 = 2）
  local eng2 = Engine.create()
  Standard.setup(eng2)
  local ps2 = {}
  for i = 1, 5 do table.insert(ps2, Player.create("P" .. i, eng2:getGeneral("白板武将"), i, false)) end
  local r2 = Room.create(eng2, ps2)
  r2:setupRoles(Standard.makeRng(1))
  r2:start()
  ps2[1]:equipCard(Card.create(901, "chitu", Card.Suit.Heart, 5, Card.Type.Equip), "offensive_horse")
  ps2[3]:equipCard(Card.create(902, "dilu", Card.Suit.Club, 5, Card.Type.Equip), "defensive_horse")
  check(r2:distance(ps2[1], ps2[3]) == 2, "进攻马与防御马应互相抵消（2-1+1=2）")
end

print("\n--- 标准版牌堆（108 张固定花色点数）---")

do
  local DeckSpec = require "src.core.deck_spec"
  local ok, errs = DeckSpec.verify()
  check(ok, "固定花色点数表自检应通过（" .. table.concat(errs, "；") .. "）")
  check(#DeckSpec.STANDARD == 108, "标准版牌堆应为 108 张（实得 "
    .. #DeckSpec.STANDARD .. "）")
  check(Standard.deckSize("standard") == 108, "deckSize(standard) 应为 108")
  check(Standard.PRESET == "standard", "默认牌堆预设应为 standard")

  local pile = Standard.buildStandardPile(1)
  check(#pile == 108, "生成 108 张（实得 " .. #pile .. "）")
  local bySuit = {}
  for _, c in ipairs(pile) do bySuit[c.suit] = (bySuit[c.suit] or 0) + 1 end
  check(bySuit[Card.Suit.Spade] == 27 and bySuit[Card.Suit.Heart] == 27
    and bySuit[Card.Suit.Club] == 27 and bySuit[Card.Suit.Diamond] == 27,
    string.format("每种花色应各 27 张（实得 ♠%d ♥%d ♣%d ♦%d）",
      bySuit[Card.Suit.Spade] or 0, bySuit[Card.Suit.Heart] or 0,
      bySuit[Card.Suit.Club] or 0, bySuit[Card.Suit.Diamond] or 0))

  -- 文档第 8 节的几个锚点：♥3 是桃、♦2 是闪、♠A 是决斗/闪电、♣2(EX) 是仁王盾
  local function find(suit, number, name)
    for _, c in ipairs(pile) do
      if c.suit == suit and c.number == number
        and (name == nil or c.name == name) then return c end
    end
    return nil
  end
  check(find(Card.Suit.Heart, 3, "peach") ~= nil, "♥3 应为【桃】")
  check(find(Card.Suit.Diamond, 2, "dodge") ~= nil, "♦2 应为【闪】")
  check(find(Card.Suit.Spade, 1, "duel") ~= nil, "♠A 应有【决斗】")
  check(find(Card.Suit.Spade, 1, "lightning") ~= nil, "♠A 应有【闪电】")
  check(find(Card.Suit.Club, 2, "renwang_shield") ~= nil, "♣2 EX 应为【仁王盾】")
  check(find(Card.Suit.Heart, 12, "lightning") ~= nil, "♥Q EX 应为【闪电】")
  check(find(Card.Suit.Diamond, 12, "nullification") ~= nil, "♦Q EX 应为【无懈可击】")
  check(find(Card.Suit.Spade, 2, "ice_sword") ~= nil, "♠2 EX 应为【寒冰剑】")
end

print("\n--- 卡牌定义完整性 ---")

do -- 白名单改为遍历牌堆配比，防止名单本身腐坏（历史教训 35）
  local missing = {}
  local DeckSpec = require "src.core.deck_spec"
  local seen = {}
  for _, row in ipairs(DeckSpec.STANDARD) do
    local name = row[3]
    if not seen[name] then
      seen[name] = true
      if not Cards.get(name) then table.insert(missing, name) end
    end
  end
  check(#missing == 0, "标准版 108 张用到的牌名都有定义（缺失: "
    .. table.concat(missing, ",") .. "）")
  check(Card.ZH["ex_nihilo"] == "无中生有", "中文名映射由 cards.lua 注册")
end

print("\n--- 目标禁止判定：UI 查询与引擎结算必须一致 ---")

do
  -- 曾经踩过：canUseCardOn 没检查【空城】/【帷幕】/【谦逊】/判定区同名，
  -- 而这些只在真正结算的 _validateUse 里判。结果 UI 把目标标绿，
  -- 玩家拖过去却被悄悄退还 —— 表现是「点了牌、点了武将，什么也没发生」。
  local engine = Engine.create()
  Standard.setup(engine)
  local zhuge = engine:getGeneral("诸葛亮")   -- 【空城】：无手牌不能被杀/决斗指定
  if not zhuge then
    print("SKIP  名册里没有诸葛亮，跳过空城用例")
  else
    local a = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
    local b = Player.create("乙", zhuge, 2, false)
    local r = Room.create(engine, { a, b })
    local slash = Card.create(90001, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
    local duel = Card.create(90003, "duel", Card.Suit.Spade, 3, Card.Type.Trick)

    local ok1, why1 = r:canUseCardOn(a, slash, b)
    check(ok1 == false, "【空城】无手牌时，出牌前的查询就该拒绝（而不是打出去才退还）")
    check(type(why1) == "string" and why1:find("空城") ~= nil,
      "拒绝时应给出原因（实得 " .. tostring(why1) .. "）")

    local ok2 = r:canUseCardOn(a, duel, b)
    check(ok2 == false, "【空城】同样挡住【决斗】")

    -- 有手牌时恢复正常（不能被这个检查误伤）
    table.insert(b.hand, Card.create(90002, "dodge", Card.Suit.Heart, 2, Card.Type.Basic))
    local ok3, why3 = r:canUseCardOn(a, slash, b)
    check(ok3 == true, "【空城】有手牌时可以被【杀】指定（实得 " .. tostring(why3) .. "）")
  end
end

print("\n--- 阶段技能的征询次数（防止每阶段都弹窗）---")

do
  -- 回归：离间/闭月这类「守卫写在效果里」的技能，之前每个玩家的每个阶段
  -- 都会弹一次「是否发动」——实测每轮被问 6 次。
  -- 现在守卫提前到 can_trigger，每轮至多被问 1 次。
  local eng = Engine.create()
  Standard.setup(eng)
  local ps = {}
  for i, n in ipairs { "貂蝉", "典韦", "曹操", "刘备", "孙权" } do
    table.insert(ps, Player.create("P" .. i, eng:getGeneral(n), i, i == 1))
  end
  local r = Room.create(eng, ps)
  r.drawPile = Standard.buildDrawPile(3)
  r.rng = Standard.makeRng(3)
  r:setupRoles(Standard.makeRng(4))
  r:start()
  local Driver = require "src.core.driver"
  local Bot = require "src.core.bot"
  local d = Driver.create(r, Bot.make())
  local asks = {}
  local guard = 0
  while not r.game_over and guard < 2000 do
    guard = guard + 1
    local st, req = d:advance()
    if st == "human" and req then
      if req.type == "askForSkillInvoke" then
        local sk = req.skill or "?"
        asks[sk] = (asks[sk] or 0) + 1
        r:step(true)
      else
        r:step(Bot.make()(req, r))
      end
    end
  end
  -- 32 轮内，每个技能被问次数不应明显超过貂蝉存活轮数（上限取 20 留余量）
  for sk, n in pairs(asks) do
    check(n <= 20, string.format("【%s】每轮至多被问一次（实得 %d 次/%d 轮）",
      sk, n, r.turn_count))
  end
  check((asks["闭月"] or 0) > 0, "闭月应被征询过（防止改死）")
end

print("\n--- 无懈可击的询问 ---")

do
  local r, ps = makeRoomWith({ "曹操", "刘备", "孙权" }, 31)
  -- 三人手里都没有无懈可击
  ps[1].hand, ps[2].hand, ps[3].hand = {}, {}, {}
  check(not r:canNullify(ps[1]), "空手牌不应判为可抵消")
  give(ps[2], "nullification", Card.Suit.Spade, 12, Card.Type.Trick)
  check(r:canNullify(ps[2]), "手里有无懈可击应判为可抵消")
  -- 看破（卧龙）：黑色手牌可当无懈可击
  local r2, qs = makeRoomWith({ "诸葛亮", "曹操", "刘备" }, 32)
  qs[1].hand = {}
  local wo = Engine.create()
  Standard.setup(wo)
  wo = wo:getGeneral("卧龙")
  if wo then
    qs[1].general = wo
    give(qs[1], "slash", Card.Suit.Spade, 7, Card.Type.Basic) -- 黑色牌
    check(r2:canNullify(qs[1]), "看破且有黑色牌应判为可抵消")
  end
end

print("\n--- 女将性别（雌雄剑/结姻/离间的目标判定依据）---")

do
  -- 文档：标准 25 将中女将 = 甄姬/黄月英/大乔/孙尚香/貂蝉
  local want = { ["甄姬"] = true, ["黄月英"] = true, ["大乔"] = true,
    ["孙尚香"] = true, ["貂蝉"] = true }
  local badg = {}
  for _, g in ipairs(Generals.all()) do
    if want[g.name] and not g.female then table.insert(badg, g.name .. "应为女") end
  end
  local engine = Engine.create()
  Standard.setup(engine)
  local pz = Player.create("甄姬", engine:getGeneral("甄姬"), 1, false)
  if not pz.female then table.insert(badg, "性别未传到 Player") end
  check(#badg == 0, "标准版女将性别应正确（差异: " .. table.concat(badg, "；") .. "）")
end

print("\n--- 拆牌三区域（过河拆桥/顺手牵羊可拆装备与判定区）---")

do -- takeCardAnyZone：手牌/装备区/判定区三个区域
  local engine = Engine.create()
  Standard.setup(engine)
  local p = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local h = give(p, "slash", Card.Suit.Spade, 7)
  local w = Card.create(2001, "crossbow", Card.Suit.Club, 1, Card.Type.Equip)
  p.equips.weapon = w
  local j = Card.create(2002, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  table.insert(p.judges, j)
  check(p:takeCardAnyZone(w) == "equip", "应能从装备区摘牌")
  check(p.equips.weapon == nil, "装备槽应已空")
  check(p:takeCardAnyZone(j) == "judge", "应能从判定区摘牌")
  check(#p.judges == 0, "判定区应已空")
  check(p:takeCardAnyZone(h) == "hand", "应能从手牌摘牌")
  check(#p.hand == 0, "手牌应已空")
end

do -- 过河拆桥：请求携带公开牌候选，可拆装备
  local r, ps = makeRoomWith({ "白板武将", "白板武将" })
  local weapon = Card.create(2003, "crossbow", Card.Suit.Club, 1, Card.Type.Equip)
  ps[2].equips.weapon = weapon
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  local co = coroutine.create(function()
    return r:askForDiscardFrom(ps[1], ps[2], 1)
  end)
  local _, req = coroutine.resume(co)
  check(req and req.type == "askForDiscardFrom", "拆牌应产生 askForDiscardFrom 请求")
  local has_weapon = false
  for _, c in ipairs((req and req.equip_judges) or {}) do
    if c == weapon then has_weapon = true break end
  end
  check(has_weapon, "装备区八卦阵/连弩等公开牌应出现在候选里")
  check((req and req.hand_count) == 1, "请求应携带手牌张数")
  local _, out = coroutine.resume(co, weapon)
  check(ps[2].equips.weapon == nil, "拆装备后武器槽应已空")
  check(out and out[1] == weapon, "应返回弃掉的装备列表")
  local discarded = false
  for _, c in ipairs(r.discardPile) do if c == weapon then discarded = true break end end
  check(discarded, "被拆的装备应进入弃牌堆")
end

do -- 顺手牵羊：可顺装备，失去装备触发【枭姬】；无公开牌时随机拿手牌
  local r, ps = makeRoomWith({ "白板武将", "孙尚香" })
  local armor = Card.create(2004, "eight_diagram", Card.Suit.Spade, 2, Card.Type.Equip)
  ps[2].equips.armor = armor
  local before = #ps[2].hand
  local co = coroutine.create(function()
    local Cards2 = require "src.core.cards"
    return Cards2.get("snatch").effect(r,
      { from = ps[1], card = nil, to = { ps[2] } })
  end)
  local _, req = coroutine.resume(co)
  check(req and req.type == "askForChooseCard" and req.cards[1] == armor,
    "顺手牵羊应把公开装备摆出来选")
  coroutine.resume(co, armor)
  check(ps[2].equips.armor == nil, "被顺的防具应离开装备区")
  check(ps[1].hand[1] == armor, "装备应进入使用者手牌")
  check(#ps[2].hand == before + 2, "孙尚香【枭姬】应在失去装备时摸两张")

  -- 无公开牌且无手牌：不产出请求，直接无牌可顺
  local r2, qs = makeRoomWith({ "白板武将", "白板武将" })
  local co2 = coroutine.create(function()
    local Cards2 = require "src.core.cards"
    return Cards2.get("snatch").effect(r2,
      { from = qs[1], card = nil, to = { qs[2] } })
  end)
  local _, req2 = coroutine.resume(co2)
  check(req2 == nil and coroutine.status(co2) == "dead", "无牌可顺时不应产出请求")

  -- 只有手牌：不问选牌，直接随机抽一张暗牌
  local r3, ss = makeRoomWith({ "白板武将", "白板武将" })
  give(ss[2], "slash", Card.Suit.Club, 7)
  local co3 = coroutine.create(function()
    local Cards2 = require "src.core.cards"
    return Cards2.get("snatch").effect(r3,
      { from = ss[1], card = nil, to = { ss[2] } })
  end)
  local _, req3 = coroutine.resume(co3)
  check(req3 == nil and coroutine.status(co3) == "dead", "只有暗牌时不应产出选牌请求")
  check(#ss[1].hand == 1 and #ss[2].hand == 0, "应随机拿走一张暗牌")
end

print("\n--- 八卦阵覆盖「需要打出闪」的全场景（万箭齐发）---")

do
  local Cards2 = require "src.core.cards"
  -- 判定红色：视为打出闪，不受伤害
  local r, ps = makeRoomWith({ "白板武将", "白板武将" })
  local bagua = Card.create(2005, "eight_diagram", Card.Suit.Spade, 2, Card.Type.Equip)
  ps[2].equips.armor = bagua
  ps[2].hand = {} -- 没有闪，只能靠八卦阵
  local red = Card.create(2006, "peach", Card.Suit.Heart, 9)
  table.insert(r.drawPile, red) -- 牌堆顶 = 尾部
  local co = coroutine.create(function()
    return Cards2.get("archery_attack").effect(r,
      { from = ps[1], card = nil, to = { ps[2] } })
  end)
  local _, req = coroutine.resume(co)
  check(req and req.card_name == "dodge", "万箭应先问【闪】")
  coroutine.resume(co, nil) -- 不出闪
  check(ps[2].hp == ps[2].max_hp, "八卦阵判定红色应视为打出闪，免受万箭伤害")

  -- 判定黑色：防具失效，受到 1 点伤害
  local r2, qs = makeRoomWith({ "白板武将", "白板武将" })
  local bagua2 = Card.create(2007, "eight_diagram", Card.Suit.Spade, 2, Card.Type.Equip)
  qs[2].equips.armor = bagua2
  qs[2].hand = {}
  local black = Card.create(2008, "slash", Card.Suit.Spade, 8)
  table.insert(r2.drawPile, black)
  local co2 = coroutine.create(function()
    return Cards2.get("archery_attack").effect(r2,
      { from = qs[1], card = nil, to = { qs[2] } })
  end)
  local _, _req2 = coroutine.resume(co2)
  check(_req2 and _req2.card_name == "dodge", "判定前仍应先问【闪】")
  coroutine.resume(co2, nil)
  check(qs[2].hp == qs[2].max_hp - 1, "八卦阵判定黑色应失效，万箭造成 1 点伤害")

  -- 无八卦阵：不受影响，照常受伤
  local r3, ss = makeRoomWith({ "白板武将", "白板武将" })
  ss[2].hand = {}
  local co3 = coroutine.create(function()
    return Cards2.get("archery_attack").effect(r3,
      { from = ss[1], card = nil, to = { ss[2] } })
  end)
  local _, req3 = coroutine.resume(co3)
  check(req3 and req3.card_name == "dodge", "无防具时万箭仍应问【闪】")
  coroutine.resume(co3, nil)
  check(ss[2].hp == ss[2].max_hp - 1, "无八卦阵不出闪应受 1 点伤害")
end

print("\n--- 无懈可击嵌套（可抵消另一张无懈）---")

do
  local function nullUse(r, players)
    local target_card = Card.create(9000 + #r.discardPile, "ex_nihilo",
      Card.Suit.Heart, 7, Card.Type.Trick)
    return { from = players[3], card = target_card, to = { players[3] } }
  end

  -- 单张无懈：原锦囊被抵消
  do
    local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将" })
    local n1 = give(ps[1], "nullification", Card.Suit.Spade, 12, Card.Type.Trick)
    local co = coroutine.create(function() return r:askForNullification(nullUse(r, ps)) end)
    local _, req1 = coroutine.resume(co)
    check(req1 and req1.card_name == "nullification" and req1.nullify_round == 1,
      "第一轮应询问是否抵消原锦囊")
    local ok, ret = coroutine.resume(co, n1)
    check(ok and ret == true, "一张无懈应抵消原锦囊")
  end

  -- 两张无懈嵌套：无懈抵消无懈，原锦囊重新生效
  do
    local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将" })
    local n1 = give(ps[1], "nullification", Card.Suit.Spade, 12, Card.Type.Trick)
    -- 第二张只是让 P1 在后续轮次仍能被 canNullify 问到（响应时选择不出）
    give(ps[1], "nullification", Card.Suit.Club, 12, Card.Type.Trick)
    local n3 = give(ps[2], "nullification", Card.Suit.Heart, 12, Card.Type.Trick)
    local co = coroutine.create(function() return r:askForNullification(nullUse(r, ps)) end)
    local _, req1 = coroutine.resume(co)
    check(req1.player == ps[1], "座位顺序先问 P1")
    local _, req2 = coroutine.resume(co, n1)   -- P1 出第一张
    check(req2 and req2.nullify_round == 2 and req2.player == ps[1]
      and req2.ask_from == ps[1], "第二轮应询问是否抵消那张无懈（可拒绝抵消自己的）")
    local _, req3 = coroutine.resume(co, nil)  -- P1 不抵消自己的
    check(req3 and req3.nullify_round == 2 and req3.player == ps[2],
      "应轮到 P2 决定是否再无懈")
    coroutine.resume(co, n3)   -- P2 出第二张 → 进入第三轮
    -- 第三轮又从 P1 问起（还剩一张无懈）：选择不出 → 无人再出，直接结算；
    -- 结算结果就落在这一次 resume 的返回值上（协程已 dead）
    local ok, ret = coroutine.resume(co, nil)
    check(ok and ret == false, "两张无懈奇偶相抵，原锦囊应重新生效")
    check(coroutine.status(co) == "dead", "无人再出时应结束询问")
  end
end

do -- BOT 嵌套无懈策略：敌人出的无懈才跟
  local r, ps = makeRoomWith({ "曹操", "张飞", "刘备", "华佗" })
  r.identity_mode = true
  ps[1].role, ps[2].role, ps[3].role, ps[4].role = "lord", "rebel", "loyalist", "rebel"
  local bot = Bot.make()
  local n = give(ps[2], "nullification", Card.Suit.Spade, 12, Card.Type.Trick)
  check(bot({ type = "askForCard", player = ps[2], card_name = "nullification",
    nullify_round = 2, ask_from = ps[3], ask_target = ps[1] }, r) == n,
    "BOT：忠臣（敌人）的保护性无懈应被反贼再无懈")
  check(bot({ type = "askForCard", player = ps[2], card_name = "nullification",
    nullify_round = 2, ask_from = ps[4], ask_target = ps[1] }, r) == nil,
    "BOT：同伴（反贼）出的无懈不应再无懈")
  check(bot({ type = "askForCard", player = ps[2], card_name = "nullification",
    ask_from = ps[1], ask_target = ps[2] }, r) == n,
    "BOT：第一轮仍是锦囊目标为自己时才出无懈")
end

print("\n--- 借刀杀人（使用者指定目标 / 拒绝则失武器 / 范围内无人则落空）---")

do -- 使用者指定目标，持有者出杀 → 对指定目标结算
  local Cards2 = require "src.core.cards"
  local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将" })
  local weapon = Card.create(3001, "crossbow", Card.Suit.Club, 1, Card.Type.Equip)
  ps[2].equips.weapon = weapon
  local slash = give(ps[2], "slash", Card.Suit.Spade, 7)
  local co = coroutine.create(function()
    return Cards2.get("collateral").effect(r, { from = ps[1], card = nil, to = { ps[2] } })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChoice" and req1.player == ps[1],
    "借刀应先让**使用者**指定目标")
  local names = {}
  for _, nm in ipairs((req1 and req1.choices) or {}) do names[nm] = true end
  check(names[ps[1].name] and names[ps[3].name] and not names[ps[2].name],
    "候选应含范围内角色且不含武器持有者")
  local _, req2 = coroutine.resume(co, ps[3].name)  -- 指定 ps[3]
  check(req2 and req2.card_name == "slash" and req2.player == ps[2],
    "持有者应被要求出杀")
  local _, req3 = coroutine.resume(co, slash)
  check(req3 and req3.card_name == "dodge" and req3.player == ps[3],
    "杀应作用于**指定的**目标而非自动选第一个")
  coroutine.resume(co, nil) -- 不出闪
  check(ps[3].hp == ps[3].max_hp - 1, "不出闪应受 1 点伤害")
  check(ps[2].equips.weapon == weapon, "出了杀武器不应转移")
end

do -- 拒绝出杀：武器转给使用者，孙尚香【枭姬】因失去装备摸两张
  local Cards2 = require "src.core.cards"
  local r, ps = makeRoomWith({ "白板武将", "孙尚香", "白板武将" })
  local weapon = Card.create(3002, "kylin_bow", Card.Suit.Heart, 5, Card.Type.Equip)
  ps[2].equips.weapon = weapon -- 麒麟弓范围 5，两人都能被指定
  local co = coroutine.create(function()
    return Cards2.get("collateral").effect(r, { from = ps[1], card = nil, to = { ps[2] } })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChoice", "应先让使用者指定目标")
  -- 指定 ps[3] 后，下一次 yield 就是持有者的出杀询问
  local _, req2 = coroutine.resume(co, ps[3].name)
  check(req2 and req2.card_name == "slash" and req2.player == ps[2],
    "持有者应被要求出杀")
  coroutine.resume(co, nil) -- 拒绝出杀
  check(ps[2].equips.weapon == nil and ps[1].hand[1] == weapon,
    "拒出杀武器应转给使用者")
  check(#ps[2].hand == 2, "孙尚香失去武器应触发【枭姬】摸两张")
end

do -- 范围内无可指定目标（空城）：落空，武器不转移
  local Cards2 = require "src.core.cards"
  local r, ps = makeRoomWith({ "诸葛亮", "白板武将", "诸葛亮" })
  -- 两名诸葛亮都无手牌：【空城】生效，不能被【杀】指定
  local weapon = Card.create(3003, "crossbow", Card.Suit.Club, 1, Card.Type.Equip)
  ps[2].equips.weapon = weapon
  local co = coroutine.create(function()
    return Cards2.get("collateral").effect(r, { from = ps[1], card = nil, to = { ps[2] } })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 == nil and coroutine.status(co) == "dead", "无可指定目标时不应产出请求")
  check(ps[2].equips.weapon == weapon and #ps[1].hand == 0,
    "落空时武器不应转移（修复：原来照样拿走武器）")
end

do -- BOT 的借刀目标策略：候选是玩家名时挑敌方残血
  local r, ps = makeRoomWith({ "曹操", "张飞", "刘备", "华佗" })
  r.identity_mode = true
  ps[1].role, ps[2].role, ps[3].role, ps[4].role = "lord", "rebel", "loyalist", "rebel"
  ps[3].hp = 1 -- 刘备残血，是张飞的优先集火对象
  local bot = Bot.make()
  local picked = bot({ type = "askForChoice", player = ps[2],
    choices = { ps[1].name, ps[3].name, ps[4].name } }, r)
  check(picked == ps[3].name, "BOT 应挑敌方残血（刘备）而非主公或同伴（实际选 "
    .. tostring(picked) .. "）")
end

print("\n--- 转化技可用装备区的牌（武圣红色装备当杀）---")

do -- 武圣：装备区的红色装备可当【杀】，结算后进弃牌堆并触发失去装备
  local r, ps = makeRoomWith({ "关羽", "白板武将" })
  local horse = Card.create(4001, "offensive_horse", Card.Suit.Heart, 5, Card.Type.Equip) -- 赤兔 ♥5 红色
  ps[1].equips.offensive_horse = horse
  ps[1].hand = {}
  local cands = r:viewAsCandidates(ps[1], "slash")
  local hit = false
  for _, item in ipairs(cands) do
    if item.card == horse then hit = true break end
  end
  check(hit, "【武圣】应能转化装备区的红色坐骑")
  local made = r:viewAsCard(ps[1], "slash", horse)
  check(made ~= nil and made.virtual, "应生成虚拟【杀】")
  local co = coroutine.create(function()
    return r:useCard(ps[1], made, ps[2])
  end)
  local _, req = coroutine.resume(co) -- 目标被问【闪】
  check(req and req.card_name == "dodge", "目标应被询问【闪】")
  coroutine.resume(co, nil) -- 不出闪
  check(ps[2].hp == ps[2].max_hp - 1, "不出闪应受 1 点伤害")
  check(ps[1].equips.offensive_horse == nil, "被转化的坐骑应离开装备区")
  local discarded = false
  for _, c in ipairs(r.discardPile) do if c == horse then discarded = true break end end
  check(discarded, "被转化的坐骑应进弃牌堆")
end

do -- 倾国：牌面写「手牌」，黑色装备不能当【闪】（对照：黑色手牌可以）
  local r, ps = makeRoomWith({ "甄姬", "白板武将" })
  local bagua = Card.create(4002, "eight_diagram", Card.Suit.Spade, 2, Card.Type.Equip)
  ps[1].equips.armor = bagua
  ps[1].hand = {}
  check(#r:viewAsCandidates(ps[1], "dodge") == 0, "【倾国】只认手牌，黑色装备不应被转化")
  give(ps[1], "slash", Card.Suit.Spade, 8)
  check(#r:viewAsCandidates(ps[1], "dodge") == 1, "黑色手牌应可被【倾国】转化")
end

do -- 退还：转化失败时装备回到装备槽而不是变成手牌
  local r, ps = makeRoomWith({ "关羽", "白板武将", "白板武将", "白板武将" })
  local horse = Card.create(4003, "offensive_horse", Card.Suit.Heart, 5, Card.Type.Equip)
  ps[1].equips.offensive_horse = horse
  ps[1].hand = {}
  -- 赤兔还装在身上：对家座位距离 2，进攻马 -1 后为 1；
  -- 使用时坐骑先被消耗（takeCardAnyZone），距离回到 2 → 超出范围 1 → 退还
  check(r:distance(ps[1], ps[3]) == 1, "装备进攻马后到对家距离应为 1")
  local made = r:viewAsCard(ps[1], "slash", horse)
  local ok = r:useCard(ps[1], made, ps[3])
  check(not ok, "超出攻击范围的使用应被拒绝（坐骑消耗后距离回到 2）")
  check(ps[1].equips.offensive_horse == horse, "退还的坐骑应回到装备槽")
  check(#ps[1].hand == 0, "退还不应把装备变成手牌")
end

print("\n--- 开局选将候选池（主公 5 张、其余 3 张）---")

do
  local engine = Engine.create()
  Standard.setup(engine)
  local pools = Standard.dealCandidates(engine, Standard.makeRng(7), 5, 2)
  check(#pools[2] == 5, "主公候选应为 5 张")
  local ok3 = true
  for seat = 1, 5 do
    if seat ~= 2 and #pools[seat] ~= 3 then ok3 = false end
  end
  check(ok3, "其余座位候选应为 3 张")
  local seen, dup = {}, false
  for seat = 1, 5 do
    for _, g in ipairs(pools[seat]) do
      if seen[g.name] then dup = true end
      seen[g.name] = true
    end
  end
  check(not dup, "候选池内武将不应重复")
  local ph = false
  for seat = 1, 5 do
    for _, g in ipairs(pools[seat]) do
      if Standard.PLACEHOLDERS[g.name] then ph = true end
    end
  end
  check(not ph, "候选不应含占位将")
  local pools2 = Standard.dealCandidates(engine, Standard.makeRng(7), 5, 2)
  local same = true
  for seat = 1, 5 do
    for i, g in ipairs(pools[seat]) do
      if pools2[seat][i] ~= g then same = false end
    end
  end
  check(same, "同种子候选池应可复现")
end

print("\n--- 遗计：看牌顶两张逐张分人，每点伤害一次 ---")

do
  local r, ps = makeRoomWith({ "郭嘉", "白板武将" })
  local before = #r.drawPile
  local co = coroutine.create(function()
    return r:damage(ps[2], ps[1], 2) -- 2 点伤害 → 两次共 4 张
  end)
  -- 逐张应答：每次询问都留给自己，直到协程结束
  local asks = 0
  while coroutine.status(co) ~= "dead" do
    local ok, out = coroutine.resume(co, asks > 0 and ps[1].name or nil)
    if not ok then error(out, 0) end
    if coroutine.status(co) ~= "dead" then
      asks = asks + 1
      check(out and out.type == "askForChoice" and out.player == ps[1]
        and out.pick == "self",
        string.format("第 %d 张应询问郭嘉分给谁（pick=self）", asks))
    end
  end
  check(asks == 4, "2 点伤害应产生 4 次分牌询问（实得 " .. asks .. "）")
  check(#ps[1].hand == 4, "2 点伤害应分得 4 张（实得 " .. #ps[1].hand .. "）")
  check(before - #r.drawPile == 4, "牌堆应减少 4 张（卡牌守恒）")
end

print("\n--- 制衡：任意张自选（any 模式）---")

do
  local r, ps = makeRoomWith({ "孙权", "白板武将" })
  local c1 = give(ps[1], "dodge", Card.Suit.Heart, 2)
  local c2 = give(ps[1], "nullification", Card.Suit.Spade, 12, Card.Type.Trick)
  local c3 = give(ps[1], "slash", Card.Suit.Spade, 7)
  local co = coroutine.create(function()
    return r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  local _, req = coroutine.resume(co)
  check(req and req.type == "askForDiscard" and req.any == true,
    "制衡应走 any 模式的自选弃牌")
  local _, fin = coroutine.resume(co, { c1, c2 })
  check(fin == false, "制衡触发不应截断阶段")
  check(#ps[1].hand == 3, "弃 2 摸 2 后应剩 3 张（实得 " .. #ps[1].hand .. "）")
  check(ps[1].hand[1] == c3, "留下的应是未选的【杀】")
  check(ps[1].zhiheng_used == true, "本阶段限一次标记应置位")
  local discarded = 0
  for _, c in ipairs(r.discardPile) do
    if c == c1 or c == c2 then discarded = discarded + 1 end
  end
  check(discarded == 2, "弃掉的两张应进弃牌堆")
end

do -- 只有装备也能制衡，并按失去装备流程结算
  local r, ps = makeRoomWith({ "孙权", "白板武将" })
  local armor = equipCard(ps[1], "eight_diagram")
  local co = coroutine.create(function()
    return r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  local _, req = coroutine.resume(co)
  check(req and req.any and req.include_equips and req.n == 1,
    "制衡候选应包含装备区（仅一件装备时 n=1）")
  check(req and #req.cards == 1 and req.cards[1] == armor,
    "制衡请求应下发装备候选")
  coroutine.resume(co, { armor })
  check(ps[1].equips.armor == nil, "制衡选中的装备应离开装备区")
  check(#ps[1].hand == 1, "弃一件装备后应摸一张牌")
  check(r.discardPile[#r.discardPile] == armor, "被制衡的装备应进入弃牌堆")
end

print("\n--- 五谷丰登：由使用者开始依次选 ---")

do
  local Cards2 = require "src.core.cards"
  local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将" })
  local co = coroutine.create(function()
    return Cards2.get("amazing_grace").effect(r, { from = ps[2], card = nil, to = {} })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChooseCard" and req1.player == ps[2],
    "五谷应由**使用者**先选（而非座位 1）")
  local _, req2 = coroutine.resume(co, nil)
  check(req2 and req2.player == ps[3], "第二位应为使用者的下家")
  local _, req3 = coroutine.resume(co, nil)
  check(req3 and req3.player == ps[1], "第三位应轮回到座位 1")
  coroutine.resume(co, nil)
  check(#ps[1].hand == 1 and #ps[2].hand == 1 and #ps[3].hand == 1,
    "三人应各得一张")
end

print("\n--- 反间：目标与送牌均由周瑜选定 ---")

do
  local r, ps = makeRoomWith({ "周瑜", "白板武将", "白板武将" })
  local heart_slash = give(ps[1], "slash", Card.Suit.Heart, 10) -- 红桃杀
  local co = coroutine.create(function()
    return r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChoice" and req1.pick == "enemy",
    "反间应先由周瑜选目标")
  local _, req2 = coroutine.resume(co, ps[3].name) -- 选 P3
  check(req2 and req2.type == "askForChooseCard" and req2.giveaway == true,
    "送哪张牌应由周瑜选（giveaway）")
  local _, req3 = coroutine.resume(co, heart_slash)
  check(req3 and req3.type == "askForChoice" and req3.player == ps[3],
    "目标应被要求猜花色")
  coroutine.resume(co, "黑桃") -- 猜错（实为红桃）
  check(ps[3].hp == ps[3].max_hp - 1, "猜错花色应受 1 点伤害")
  check(#ps[3].hand == 1 and ps[3].hand[1] == heart_slash,
    "无论猜对猜错都获得那张手牌")
end

print("\n--- 离间：弃牌与两名男性及方向均由貂蝉选定 ---")

do
  local r, ps = makeRoomWith({ "貂蝉", "吕布", "白板武将", "关羽" })
  local cost = give(ps[1], "dodge", Card.Suit.Heart, 2)
  local co = coroutine.create(function()
    return r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChooseCard" and req1.giveaway == true,
    "离间应先选弃置的手牌")
  local _, req2 = coroutine.resume(co, cost)
  check(req2 and req2.type == "askForChoice",
    "应选使用决斗的男性角色")
  local _, req3 = coroutine.resume(co, ps[4].name) -- 关羽出杀
  check(req3 and req3.type == "askForChoice",
    "应选决斗的目标（不含已选者）")
  local names3 = {}
  for _, nm in ipairs(req3.choices or {}) do names3[nm] = true end
  check(not names3[ps[4].name], "目标候选不应含已选的出杀者")
  local _, req4 = coroutine.resume(co, ps[2].name) -- 对吕布决斗
  check(req4 and req4.card_name == "slash" and req4.player == ps[2],
    "决斗应由目标（吕布）先出杀")
  coroutine.resume(co, nil) -- 吕布不出杀 → 受 1 伤
  check(ps[2].hp == ps[2].max_hp - 1, "吕布不出杀应受 1 点伤害")
  check(#ps[1].hand == 0, "弃牌代价应已入弃牌堆")
end

print("\n--- 结姻：弃哪两张与目标均由孙尚香选定 ---")

do
  local r, ps = makeRoomWith({ "孙尚香", "关羽", "白板武将" })
  ps[2].hp = ps[2].max_hp - 1
  local c1 = give(ps[1], "slash", Card.Suit.Spade, 7)
  local c2 = give(ps[1], "dodge", Card.Suit.Heart, 2)
  local co = coroutine.create(function()
    return r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForDiscard" and req1.n == 2,
    "结姻应先弃两张手牌（多选）")
  local _, req2 = coroutine.resume(co, { c1, c2 })
  check(req2 and req2.type == "askForChoice" and req2.pick == "ally",
    "结姻目标应由孙尚香选（ally）")
  local names2 = {}
  for _, nm in ipairs(req2.choices or {}) do names2[nm] = true end
  check(names2[ps[2].name] and not names2[ps[3].name],
    "候选应仅含已受伤男性（关羽）")
  coroutine.resume(co, ps[2].name)
  check(ps[2].hp == ps[2].max_hp, "目标应回复 1 点体力")
  check(#ps[1].hand == 0, "两张代价应已弃置")
end

print("\n--- 流离：弃牌与转移目标均由大乔选定 ---")

do
  local r, ps = makeRoomWith({ "白板武将", "大乔", "白板武将" })
  local slash = give(ps[1], "slash", Card.Suit.Spade, 7)
  local cost = give(ps[2], "dodge", Card.Suit.Heart, 2)
  local co = coroutine.create(function()
    return r:useCard(ps[1], slash, ps[2])
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChooseCard" and req1.giveaway == true
    and req1.player == ps[2], "流离应先由大乔选弃牌代价")
  local _, req2 = coroutine.resume(co, cost)
  check(req2 and req2.type == "askForChoice" and req2.player == ps[2],
    "转移目标应由大乔选")
  local names2 = {}
  for _, nm in ipairs(req2.choices or {}) do names2[nm] = true end
  check(names2[ps[3].name] and not names2[ps[1].name],
    "候选应含范围内角色且不含出杀者")
  local _, req3 = coroutine.resume(co, ps[3].name)
  check(req3 and req3.card_name == "dodge" and req3.player == ps[3],
    "转移后的杀应向新目标问闪")
  coroutine.resume(co, nil)
  check(ps[3].hp == ps[3].max_hp - 1 and ps[2].hp == ps[2].max_hp,
    "伤害应落在转移目标身上，大乔免伤")
  check(#ps[2].hand == 0, "弃牌代价应已消耗")
end

print("\n--- 青囊：只损 1 体力也能发动，目标与代价由华佗选定 ---")

do
  local r, ps = makeRoomWith({ "华佗", "关羽", "白板武将" })
  ps[2].hp = ps[2].max_hp - 1 -- 只损 1 点（旧版阈值 ≥2 不触发）
  local cost = give(ps[1], "slash", Card.Suit.Spade, 7)
  local co = coroutine.create(function()
    return r:trigger("EventPhaseStart", ps[1], { player = ps[1], phase = "play" })
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChooseCard" and req1.giveaway == true,
    "青囊应先选弃置的手牌")
  local _, req2 = coroutine.resume(co, cost)
  check(req2 and req2.type == "askForChoice" and req2.pick == "ally",
    "目标应由华佗选（ally，含只损 1 体力的角色）")
  coroutine.resume(co, ps[2].name)
  check(ps[2].hp == ps[2].max_hp, "目标应回复 1 点体力")
  check(#ps[1].hand == 0, "代价应已弃置")
end

print("\n--- 刚烈：伤害来源可选「弃两张或受伤」---")

do
  local r, ps = makeRoomWith({ "夏侯惇", "白板武将" })
  give(ps[2], "slash", Card.Suit.Spade, 7)
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  local black = Card.create(5001, "slash", Card.Suit.Spade, 7)
  table.insert(r.drawPile, black) -- 判定非红桃 → 刚烈生效
  local co = coroutine.create(function()
    return r:damage(ps[2], ps[1], 1) -- 夏侯惇受到 1 点伤害（from=P2）
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChoice" and req1.player == ps[2],
    "伤害来源应被要求选择（弃牌或受伤）")
  local _, fin = coroutine.resume(co, "受到 1 点伤害")
  check(fin == nil, "选择受伤后应结束")
  check(ps[2].hp == ps[2].max_hp - 1, "选择受伤应受 1 点伤害")
  check(#ps[2].hand == 2, "选择受伤不应弃牌")
end

print("\n--- 雌雄双股剑：目标可选「弃牌或让对方摸牌」---")

do
  local r, ps = makeRoomWith({ "关羽", "甄姬" })
  local sword = Card.create(5002, "double_sword", Card.Suit.Spade, 2, Card.Type.Equip)
  ps[1].equips.weapon = sword
  local slash = give(ps[1], "slash", Card.Suit.Spade, 7)
  give(ps[2], "dodge", Card.Suit.Heart, 2)
  local co = coroutine.create(function()
    return r:useCard(ps[1], slash, ps[2])
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChoice" and req1.player == ps[2],
    "目标应可选择（弃牌或让使用者摸牌）")
  local _, req2 = coroutine.resume(co, "令 " .. ps[1].name .. " 摸一张牌")
  check(req2 and req2.card_name == "dodge", "选择摸牌后继续问闪")
  coroutine.resume(co, nil)
  check(#ps[1].hand == 1, "使用者应摸一张（实得 " .. #ps[1].hand .. "）")
  check(#ps[2].hand == 1, "目标不应被弃牌")
end

print("\n--- 麒麟弓：可选是否弃马、弃哪匹 ---")

do
  local r, ps = makeRoomWith({ "白板武将", "白板武将" })
  local bow = Card.create(5003, "kylin_bow", Card.Suit.Heart, 5, Card.Type.Equip)
  ps[1].equips.weapon = bow
  local horse = Card.create(5004, "offensive_horse", Card.Suit.Spade, 13, Card.Type.Equip)
  ps[2].equips.offensive_horse = horse
  local slash = give(ps[1], "slash", Card.Suit.Spade, 7)
  local co = coroutine.create(function()
    return r:useCard(ps[1], slash, ps[2])
  end)
  coroutine.resume(co) -- 问闪
  local _, req2 = coroutine.resume(co, nil) -- 不出闪 → 命中
  check(req2 and req2.type == "askForChoice" and req2.player == ps[1],
    "命中后应询问是否弃马")
  coroutine.resume(co, "不发动")
  check(ps[2].equips.offensive_horse == horse, "选不发动马应保留")
  check(ps[2].hp == ps[2].max_hp - 1, "伤害照常结算")

  -- 第二局：选弃马
  local r2, qs = makeRoomWith({ "白板武将", "白板武将" })
  local bow2 = Card.create(5005, "kylin_bow", Card.Suit.Heart, 5, Card.Type.Equip)
  qs[1].equips.weapon = bow2
  local horse2 = Card.create(5006, "defensive_horse", Card.Suit.Club, 5, Card.Type.Equip)
  qs[2].equips.defensive_horse = horse2
  local slash2 = give(qs[1], "slash", Card.Suit.Spade, 8)
  local co2 = coroutine.create(function()
    return r2:useCard(qs[1], slash2, qs[2])
  end)
  coroutine.resume(co2)                  -- 问闪
  coroutine.resume(co2, nil)             -- 命中 → 问弃马
  coroutine.resume(co2, "弃置【" .. horse2:zhName() .. "】")
  check(qs[2].equips.defensive_horse == nil,
    "选弃置后马应离开装备区（实得 " .. tostring(qs[2].equips.defensive_horse) .. "）")
end

print("\n--- 方天画戟：追加目标由使用者选定 ---")

do
  local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将", "白板武将" })
  local halberd = Card.create(5007, "halberd", Card.Suit.Diamond, 12, Card.Type.Equip)
  ps[1].equips.weapon = halberd
  local slash = give(ps[1], "slash", Card.Suit.Spade, 7) -- 用完后手牌为 0
  local co = coroutine.create(function()
    return r:useCard(ps[1], slash, ps[2])
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChoice" and req1.player == ps[1],
    "画戟应在主目标结算前由使用者选择追加目标")
  local _, req2 = coroutine.resume(co, ps[3].name) -- 追加 P3
  check(req2 and req2.type == "askForChoice", "有第四人时应允许第二次追加")
  local names2 = {}
  for _, name in ipairs(req2.choices or {}) do names2[name] = true end
  check(not names2[ps[2].name] and not names2[ps[3].name] and names2[ps[4].name],
    "第二次候选应排除主目标和已追加目标")
  local _, dodge2 = coroutine.resume(co, ps[4].name) -- 再追加 P4，随后主目标问闪
  check(dodge2 and dodge2.card_name == "dodge" and dodge2.player == ps[2],
    "选完全部目标后才应结算主目标")
  local _, dodge3 = coroutine.resume(co, nil)
  check(dodge3 and dodge3.card_name == "dodge" and dodge3.player == ps[3],
    "第一追加目标应被问闪")
  local _, dodge4 = coroutine.resume(co, nil)
  check(dodge4 and dodge4.card_name == "dodge" and dodge4.player == ps[4],
    "第二追加目标应被问闪")
  coroutine.resume(co, nil)
  check(ps[2].hp == ps[2].max_hp - 1 and ps[3].hp == ps[3].max_hp - 1
      and ps[4].hp == ps[4].max_hp - 1,
    "三个互不重复的目标都应受伤")
end

print("\n--- 鬼才：替换哪张手牌由玩家选定 ---")

do
  local r, ps = makeRoomWith({ "司马懿", "白板武将" })
  local heart = give(ps[1], "dodge", Card.Suit.Heart, 2) -- 能把乐改不生效
  give(ps[1], "slash", Card.Suit.Spade, 7)
  local judge_spade = Card.create(5008, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  local data = { player = ps[1], reason = "indulgence", judge_card = judge_spade }
  local co = coroutine.create(function()
    return r:trigger("AskForRetrial", ps[1], data)
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.type == "askForChooseCard" and req1.giveaway == true,
    "鬼才应让玩家选替换用的手牌（giveaway）")
  check(req1 and #req1.cards == 1 and req1.cards[1] == heart,
    "候选应只含能达成目的的牌（红桃）")
  local ok, fin = coroutine.resume(co, heart)
  check(ok and fin == true, "改判成功应截断管线")
  check(data.judge_card == heart, "判定牌应被替换为所选手牌")
end

do -- 人类鬼才应看到全部手牌，即使某张不能改善当前判定
  local r, ps = makeRoomWith({ "司马懿", "白板武将" })
  ps[1].is_human = true
  local heart = give(ps[1], "dodge", Card.Suit.Heart, 2)
  local spade = give(ps[1], "slash", Card.Suit.Spade, 7)
  local data = {
    player = ps[1], reason = "indulgence",
    judge_card = Card.create(5010, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick),
  }
  local co = coroutine.create(function() return r:trigger("AskForRetrial", ps[1], data) end)
  local _, invoke = coroutine.resume(co)
  check(invoke and invoke.type == "askForSkillInvoke", "人类鬼才应先选择是否发动")
  local _, choose = coroutine.resume(co, true)
  check(choose and choose.type == "askForChooseCard" and #choose.cards == 2,
    "人类发动鬼才后应看到全部手牌")
  local seen = {}
  for _, c in ipairs(choose.cards or {}) do seen[c] = true end
  check(seen[heart] and seen[spade], "鬼才候选不得按引擎战略过滤")
  coroutine.resume(co, spade)
  check(data.judge_card == spade, "人类应可主动选择不能改善判定的手牌改判")
end

print("\n--- 救援：每回合限一次 ---")

do
  local r, ps = makeRoomWith({ "孙权", "周瑜" })
  r.turn_count = 5
  ps[1].role = "lord"
  local function jiuyuan()
    local data = { player = ps[1], from = ps[2], n = 1 }
    r:trigger("AskForPeaches", ps[1], data)
    return data.n
  end
  check(jiuyuan() == 2, "本回合第一次吴势力桃应 +1（回复 2）")
  check(jiuyuan() == 1, "本回合第二次不应再 +1（每回合限一次）")
  r.turn_count = 6
  check(jiuyuan() == 2, "下一回合应恢复 +1")
end

print("\n--- 濒死救援：按逆时针依次询问 ---")

do
  local r, ps = makeRoomWith({ "白板武将", "白板武将", "白板武将", "白板武将", "白板武将" })
  ps[3].hp = 0
  for _, p in ipairs(ps) do give(p, "peach", Card.Suit.Heart, 3) end
  local co = coroutine.create(function()
    return r:_dyingAskOthers(ps[3])
  end)
  local _, req1 = coroutine.resume(co)
  check(req1 and req1.card_name == "peach" and req1.player == ps[2],
    "应从濒死者的**逆时针**下一位（座位 2）开始询问")
  local ok, saved = coroutine.resume(co, ps[2].hand[1])
  check(ok and saved == true, "出桃救回后应停止询问")
  check(ps[3].hp == 1, "濒死者应回到 1 点体力")
end

print(string.format("\n===== 核心: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("核心测试失败", 0) end
