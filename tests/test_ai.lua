-- AI 玩家测试：观察层 / 动作枚举 / 解析 / 降级 / 完整对局
-- 全部用 mock 传输层，不联网、不需要 API key。
-- 运行: love . --test （test_game.lua 之后跑）
if not pcall(require, "love.filesystem") then
  package.path = "./?.lua;" .. package.path
end

local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Cards = require "src.core.cards"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local Bot = require "src.core.bot"
local View = require "src.core.ai.view"
local Actions = require "src.core.ai.actions"
local Prompt = require "src.core.ai.prompt"
local Parse = require "src.core.ai.parse"
local Agent = require "src.core.ai.agent"
local Transport = require "src.core.ai.transport"

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

local function totalCards(room)
  local n = #room.drawPile + #room.discardPile
  for _, p in ipairs(room.players) do n = n + p:allCardCount() end
  return n
end

-- 建一个 5 人身份局；ai_seats 里的座位交给 AI
local function makeRoom(seed, ai_seats, n)
  n = n or 5
  local engine = Engine.create()
  Standard.setup(engine)
  local pool = { "刘备", "曹操", "孙权", "貂蝉", "吕布", "诸葛亮", "司马懿", "华佗" }
  local ps = {}
  for i = 1, n do
    local g = engine:getGeneral(pool[((i - 1) % #pool) + 1]) or engine:getGeneral("白板武将")
    local p = Player.create("P" .. i, g, i, i == 1)
    p.role_revealed = false
    table.insert(ps, p)
  end
  local room = Room.create(engine, ps)
  room.drawPile = Standard.buildDrawPile(seed)
  room.rng = Standard.makeRng(seed)
  room:setupRoles(Standard.makeRng(seed + 1))
  for _, seat in ipairs(ai_seats or {}) do
    ps[seat]:setControl("ai")
  end
  room:start()
  return room, ps
end

-- 推进到「AI 正被问到一个请求」，返回该请求；找不到返回 nil
local function advanceToRequest(room, agent, want_type)
  local driver = Driver.create(room, Bot.make(), agent)
  for _ = 1, 4000 do
    local state, req = driver:advance()
    if state == "over" then return nil end
    if state == "thinking" then
      if not want_type or (req and req.type == want_type) then return req end
      -- 不是想要的请求类型：让它走 BOT 直接答完
      room:step(Bot.make()(req, room))
    elseif state == "human" then
      room:step(Bot.make()(req, room))
    end
  end
  return nil
end

print("--- 观察层：信息隐藏 ---")

do
  local room, ps = makeRoom(7, {})
  local driver = Driver.create(room, Bot.make())
  driver:advance()
  -- 找一个属于 P1 的请求来构造观察
  local req = room.pending
  check(req ~= nil, "开局后应有一个 pending 请求")

  if req then
    local view = View.build(room, req, {})
    local me = view.me
    check(me.name == req.player.name, "观察里的『我』应是当前行动者")
    check(type(me.hand) == "table", "自己的手牌应可见")
    for _, c in ipairs(me.hand) do
      check(c.id ~= nil and c.zh ~= nil, "自己的手牌应带 id 与中文名")
      break
    end
    local leaked = 0
    for _, o in ipairs(view.others) do
      if o.hand ~= nil then leaked = leaked + 1 end
    end
    check(leaked == 0, "别人的手牌明细不应出现在观察里（泄露 " .. leaked .. " 处）")

    local hidden = 0
    for _, o in ipairs(view.others) do
      if o.role == "未知" then hidden = hidden + 1 end
    end
    check(hidden >= 1, "未亮明的身份应显示为『未知』")

    check(view.draw_pile ~= nil and view.discard_pile ~= nil, "牌堆数量应公开")
  end
end

print()
print("--- 动作枚举 ---")

do
  local room, ps = makeRoom(11, { 1 })
  local agent = Agent.create({ transport = Transport.mock { responder = function() return '{"action":1}' end } })
  local req = advanceToRequest(room, agent, "askForUseCard")
  if not req then
    check(false, "应能推进到一个出牌阶段请求")
  else
    local acts = Actions.enumerate(req, room)
    check(#acts > 0, "出牌阶段应有候选动作（" .. #acts .. " 个）")
    local last = acts[#acts]
    check(last and last.kind == "pass", "最后一个候选应是『结束出牌』")

    local bad = 0
    for _, a in ipairs(acts) do
      if not a.id then bad = bad + 1 end
      if a.kind == "use" and not a.card then bad = bad + 1 end
    end
    check(bad == 0, "每个候选都应该有编号与卡牌（异常 " .. bad .. " 个）")

    -- 候选里的「对敌目标」必须真的合法：AI 不是在规则之外行动
    local illegal = 0
    for _, a in ipairs(acts) do
      if a.kind == "use" and a.target_seat ~= req.player.seat then
        local target = nil
        for _, p in ipairs(room.players) do
          if p.seat == a.target_seat then target = p end
        end
        if not target or not room:canUseCardOn(req.player, a.card, target) then
          illegal = illegal + 1
        end
      end
    end
    check(illegal == 0, "枚举出的目标都应通过引擎校验（非法 " .. illegal .. " 个）")

    local no_pass = 0
    for _, a in ipairs(acts) do
      if a.kind == "use" and a.card.name == "dodge" then no_pass = no_pass + 1 end
    end
    check(no_pass == 0, "【闪】不能作为主动出牌的候选")
  end
end

print()
print("--- 解析：各种脏输入 ---")

do
  local room, ps = makeRoom(3, { 1 })
  local agent = Agent.create({ transport = Transport.mock { responder = function() return '{"action":1}' end } })
  local req = advanceToRequest(room, agent, "askForUseCard")
  if req then
    local acts = Actions.enumerate(req, room)
    local cases = {
      { name = "标准 JSON", text = '{"action":1,"reason":"好"}', ok = true },
      { name = "带 markdown 代码块", text = '```json\n{"action": 1}\n```', ok = true },
      { name = "前后有废话", text = '我的选择是：\n{"action":2,"reason":"x"}\n希望有帮助', ok = true },
      { name = "编号是字符串", text = '{"action":"1"}', ok = true },
      { name = "越界", text = '{"action":999}', ok = false },
      { name = "负数", text = '{"action":-1}', ok = false },
      { name = "不是 JSON", text = "我不知道", ok = false },
      { name = "空字符串", text = "", ok = false },
      { name = "缺字段", text = '{"reason":"x"}', ok = false },
    }
    for _, c in ipairs(cases) do
      local _, err = Parse.response(c.text, req, room, acts)
      check((err == nil) == c.ok, "解析：" .. c.name .. (err and ("（" .. err .. "）") or ""))
    end

    -- 选 pass 应得到 nil 响应且不报错
    local pass_id = nil
    for _, a in ipairs(acts) do
      if a.kind == "pass" then pass_id = a.id end
    end
    if pass_id then
      local resp, err = Parse.response(string.format('{"action":%d}', pass_id), req, room, acts)
      check(err == nil and resp == nil, "选择『结束出牌』应得到空响应")
    end
  else
    check(false, "解析测试需要拿到一个出牌请求")
  end
end

print()
print("--- 降级：LLM 不可靠时不能卡死 ---")

do
  -- 乱码 → 回落 BOT
  local room = makeRoom(5, { 1 })
  local agent = Agent.create({ transport = Transport.mock { responder = function() return "乱码%%%" end } })
  local resp, state = nil, nil
  local driver = Driver.create(room, Bot.make(), agent)
  local fell_back = false
  for _ = 1, 2000 do
    local st, req = driver:advance()
    if st == "over" then break end
    if st == "thinking" then
      -- 等它想完
      for _ = 1, 5 do
        local r, s = agent:respond(req, room)
        if s == "ready" then
          room:step(r)
          fell_back = agent.stats.by_fallback > 0
          break
        end
      end
    elseif st == "human" then
      room:step(Bot.make()(req, room))
    end
    if fell_back then break end
  end
  check(fell_back, "LLM 输出无法解析时应回落到规则 BOT")
  check(agent.stats.by_fallback > 0, "降级次数应被记录下来（" .. agent.stats.by_fallback .. " 次）")

  -- 没配传输层 → 直接回落，且不会返回 thinking
  local room2 = makeRoom(6, { 1 })
  local bare = Agent.create({})
  local st, _ = Driver.create(room2, Bot.make(), bare):advance()
  check(st ~= "thinking", "未配置传输层时不应进入思考状态")
end

do
  -- 异步路径：mock 故意拖 3 拍，验证真的会返回 thinking 而不是阻塞等
  local room = makeRoom(9, { 1 })
  local agent = Agent.create({
    transport = Transport.mock { delay = 3, responder = function() return '{"action":1}' end },
  })
  local req = advanceToRequest(room, agent, "askForUseCard")
  if req then
    local r1, s1 = agent:respond(req, room)
    local r2, s2 = agent:respond(req, room)
    local r3, s3 = agent:respond(req, room)
    local r4, s4 = agent:respond(req, room)
    check(s1 == "thinking" and s2 == "thinking" and s3 == "thinking",
      "结果未回来时应持续返回 thinking")
    check(s4 == "ready", "结果回来后应返回 ready")
    check(agent:isThinking() == false, "拿到结果后不应仍处于思考中")
  else
    check(false, "异步测试需要一个出牌请求")
  end
end

print()
print("--- 完整对局：AI 托管座位 ---")

-- mock 的「模型」：从候选里选一个/多个。故意用确定性 rng，保证可复现。
local function makePicker(seed)
  local rng = Standard.makeRng(seed or 1)
  return function(prompt)
    local acts = prompt.actions or {}
    if #acts == 0 then return '{"action":1}' end
    local r = prompt.view and prompt.view.request
    if r and r.type == "askForDiscard" and r.n and r.n > 1 then
      local pool = {}
      for _, a in ipairs(acts) do pool[#pool + 1] = a.id end
      local ids = {}
      for i = 1, r.n do
        if #pool == 0 then break end
        local k = rng(#pool)
        ids[#ids + 1] = pool[k]
        table.remove(pool, k)
      end
      return string.format('{"actions":[%s],"reason":"弃牌"}', table.concat(ids, ","))
    end
    return string.format('{"action":%d,"reason":"选它"}', acts[rng(#acts)].id)
  end
end

local function runAIGame(seed, ai_seats, n)
  local room = makeRoom(seed, ai_seats, n)
  local agent = Agent.create({ transport = Transport.mock { responder = makePicker(seed) } })
  local driver = Driver.create(room, Bot.make(), agent)
  local guard = 0
  while not room.game_over and guard < 200000 do
    guard = guard + 1
    local state, req = driver:advance()
    if state == "over" then break end
    if state == "thinking" then
      local resp, st = agent:respond(req, room)
      if st == "ready" then room:step(resp) end
    elseif state == "human" then
      -- 人类座位没被 AI 托管时由测试代打
      room:step(Bot.make()(req, room))
    end
  end
  return room, agent
end

do
  local bad, ai_calls = {}, 0
  for seed = 1, 3 do
    local ok, err = pcall(function()
      local room, agent = runAIGame(seed, { 1, 3 }, 5)
      assert(room.game_over, "对局未结束")
      assert(room.turn_count <= Room.MAX_TURNS, "超过最大回合数")
      assert(totalCards(room) == Standard.deckSize(),
        "卡牌不守恒 " .. totalCards(room) .. " != " .. Standard.deckSize())
      ai_calls = ai_calls + agent.stats.by_ai
    end)
    if not ok then bad[#bad + 1] = seed .. ":" .. tostring(err) end
  end
  check(#bad == 0, "AI 托管 2 个座位的 5 人局跑通 3 局"
    .. (#bad == 0 and "" or "（失败: " .. table.concat(bad, " | ") .. "）"))
  check(ai_calls > 0, "AI 确实做了决策（共 " .. ai_calls .. " 次）")
end

do
  -- 全 AI 桌，且连响应牌也问 LLM（ask_all）：最费的一条路径
  local ok, err = pcall(function()
    local room = makeRoom(21, { 1, 2, 3, 4 }, 4)
    local agent = Agent.create({
      transport = Transport.mock { responder = makePicker(21) },
      ask_all = true,
    })
    local driver = Driver.create(room, Bot.make(), agent)
    local guard = 0
    while not room.game_over and guard < 200000 do
      guard = guard + 1
      local state, req = driver:advance()
      if state == "over" then break end
      if state == "thinking" then
        local resp, st = agent:respond(req, room)
        if st == "ready" then room:step(resp) end
      elseif state == "human" then
        room:step(Bot.make()(req, room))
      end
    end
    assert(room.game_over, "对局未结束")
    assert(totalCards(room) == Standard.deckSize(), "卡牌不守恒")
  end)
  check(ok, "全 AI 桌（含响应牌）能正常打完" .. (ok and "" or ("：" .. tostring(err))))
end

do
  -- AI 托管「人类座位」：Driver 不能停在 human，否则界面永远等点击
  local room = makeRoom(33, { 1 }, 5)
  local human_seat = room.players[1]
  check(human_seat.is_human == true, "1 号位仍是人类座位（手牌可见）")
  check(human_seat:controlMode() == "ai", "1 号位已交给 AI 决策")
  local agent = Agent.create({ transport = Transport.mock { responder = makePicker(33) } })
  local driver = Driver.create(room, Bot.make(), agent)
  local stuck_on_human = false
  local guard = 0
  while not room.game_over and guard < 200000 do
    guard = guard + 1
    local state, req = driver:advance()
    if state == "over" then break end
    if state == "human" then
      stuck_on_human = (req.player == human_seat)
      break
    end
    if state == "thinking" then
      local resp, st = agent:respond(req, room)
      if st == "ready" then room:step(resp) end
    end
  end
  check(not stuck_on_human, "AI 托管人类座位时不应停在等点击")
  check(room.game_over, "AI 托管人类座位的对局应能结束")
end

print()
print("--- 传输层：不联网的部分 ---")

do
  -- 真实接口长什么样、出错时怎么报，都在这里定死；curl 本身是真发请求才走得到
  local Curl = Transport.Curl
  local ok_resp = '{"choices":[{"message":{"content":"{\\"action\\": 2}"}}]}'
  local r = Curl.parse(ok_resp)
  check(r.ok and r.text == '{"action": 2}', "应能取出标准响应里的 content")

  local e1 = Curl.parse('{"error":{"message":"bad key"}}')
  check(e1.ok == false and e1.err:find("bad key") ~= nil, "接口报错应带出错误信息")

  local e2 = Curl.parse("")
  check(e2.ok == false, "空响应应判为失败")

  local e3 = Curl.parse("not json at all")
  check(e3.ok == false, "非 JSON 响应应判为失败")

  local c = Transport.curl { model = "test-model", api_key = "sk-x" }
  local body = c:_body({ system = "S", user = "U" })
  local data = require("src.core.json").decode(body)
  check(data and data.model == "test-model", "请求体应带上模型名")
  check(data and data.messages and #data.messages == 2, "请求体应是 system + user 两条消息")
  check(data and data.messages[1].content == "S", "system 消息内容应正确")
end

print()
print("--- 提示词 ---")

do
  local room = makeRoom(13, { 1 })
  local agent = Agent.create({ transport = Transport.mock { responder = function() return '{"action":1}' end } })
  local req = advanceToRequest(room, agent, "askForUseCard")
  if req then
    local acts = Actions.enumerate(req, room)
    local p = Prompt.build(room, req, acts, {})
    check(type(p.system) == "string" and #p.system > 50, "应生成 system 提示词")
    check(p.user:find("合法动作") ~= nil, "user 提示词应列出合法动作")
    check(p.user:find("输出格式") ~= nil, "user 提示词应说明输出格式")
    -- 候选编号必须都出现在提示词正文里，否则 LLM 无从选择
    local missing = 0
    for _, a in ipairs(acts) do
      if not p.user:find("\n  " .. a.id .. ". ", 1, true) then missing = missing + 1 end
    end
    check(missing == 0, "所有候选编号都应出现在提示词里（缺失 " .. missing .. " 个）")
  else
    check(false, "提示词测试需要一个出牌请求")
  end
end

print(string.format("\n===== AI 测试: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("AI 测试失败", 0) end
