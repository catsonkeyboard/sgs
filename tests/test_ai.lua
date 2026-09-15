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
print("--- 观星：AI 重排牌堆顶 ---")

do
  -- 诸葛亮在座位 1：回合开始的第一个询问就是【观星】。
  -- 注意座位要建成非人类（is_human=false）：人类座位的非锁定技会先弹
  -- 「是否发动」征询，而 advanceToRequest 对非目标类型用 BOT 应答，
  -- BOT 对技能征询答 nil（不发动），观星就永远不触发。
  local engine = Engine.create()
  Standard.setup(engine)
  local pool = { "诸葛亮", "曹操", "孙权", "貂蝉", "吕布" }
  local ps = {}
  for i = 1, 5 do
    local g = engine:getGeneral(pool[i]) or engine:getGeneral("白板武将")
    table.insert(ps, Player.create("P" .. i, g, i, false))
  end
  local room = Room.create(engine, ps)
  room.drawPile = Standard.buildDrawPile(42)
  room.rng = Standard.makeRng(42)
  room:setupRoles(Standard.makeRng(43))
  ps[1]:setControl("ai")
  room:start()

  local agent = Agent.create({
    transport = Transport.mock { responder = function() return '{"action":1}' end },
  })
  local req = advanceToRequest(room, agent, "askForGuanxing")
  check(req ~= nil, "诸葛亮回合开始应弹出观星询问")
  if req then
    check(#req.cards == 5, "5 人局观星应看 5 张（实得 " .. #req.cards .. "）")

    local acts = Actions.enumerate(req, room)
    check(#acts >= #req.cards + 3, "观星应有有界候选集（实得 " .. #acts .. " 个）")
    check(acts[1].kind == "guanxing" and #acts[1].down == 0,
      "第一个候选应是『原序放顶』")

    -- 不变量：每个候选都是这 5 张牌的一个划分（顶 + 底 = 全部，无重复）
    local bad = 0
    for _, a in ipairs(acts) do
      local seen = {}
      for _, c in ipairs(a.up) do
        if seen[c] then bad = bad + 1 end
        seen[c] = true
      end
      for _, c in ipairs(a.down) do
        if seen[c] then bad = bad + 1 end
        seen[c] = true
      end
      local total = 0
      for _ in pairs(seen) do total = total + 1 end
      if total ~= #req.cards then bad = bad + 1 end
    end
    check(bad == 0, "每个观星候选都是完整且不重复的划分（异常 " .. bad .. " 个）")

    -- 解析：原序 → 直接把候选里的 up/down 交给引擎
    local resp, err = Parse.response('{"action":1,"reason":"原序"}', req, room, acts)
    check(err == nil and type(resp) == "table" and resp.up == acts[1].up,
      "选『原序』应返回预构造的 up/down 表")

    -- 解析：沉底某一张 → down 恰一张、up 少一张
    local sink = nil
    for _, a in ipairs(acts) do
      if #a.down == 1 and #a.up == #req.cards - 1 then sink = a end
    end
    check(sink ~= nil, "应有『单张沉底』候选")
    if sink then
      local r2, e2 = Parse.response(string.format('{"action":%d}', sink.id), req, room, acts)
      check(e2 == nil and #r2.down == 1 and #r2.up == #req.cards - 1,
        "选『沉底』应正确带回 up/down")
      check(r2.down[1] ~= nil and r2.up[1] ~= nil, "沉底候选应携带真实 Card 对象")
    end

    -- 机械兜底：观星返回 nil = 引擎保持原序的约定
    local bare = Agent.create({})
    local mresp, mst = bare:respond(req, room)
    check(mst == "ready" and mresp == nil, "机械兜底对观星应返回 nil（保持原序）")

    -- 引擎吃下重排：up[1] 是牌堆顶，摸牌阶段先摸到它（再摸 up[2]）
    if resp then
      local before = #ps[1].hand
      room:step(resp)
      local h = ps[1].hand
      check(#h >= before + 2, "观星后应正常进入摸牌阶段")
      check(h[#h - 1] == resp.up[1] and h[#h] == resp.up[2],
        "应按重排后的顶序摸牌（先摸 up[1] 那张）")
    end
  end
end

print()
print("--- 解析：各种脏输入 ---")

do
  local room = makeRoom(3, { 1 })
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
  -- 模型彻底失联（一直输出乱码）：先重试，再机械兜底，**不调用规则 BOT**
  local agent = Agent.create({
    transport = Transport.mock { responder = function() return "乱码%%%，我选第一个" end },
    retries = 1,
  })
  local driver = Driver.create(room, Bot.make(), agent)
  local guard = 0
  while not room.game_over and guard < 30000 do
    guard = guard + 1
    local st, req = driver:advance()
    if st == "over" then break end
    if st == "thinking" then
      local r, s = agent:respond(req, room)
      if s == "ready" then room:step(r) end
    elseif st == "human" then
      room:step(Bot.make()(req, room))
    end
  end
  check(room.game_over, "模型完全失效时对局仍应正常结束（靠机械兜底）")
  check(agent.stats.mechanical > 0,
    "应记录机械兜底次数（" .. agent.stats.mechanical .. " 次）")
  check(agent.stats.retried > 0,
    "解析失败时先重试（" .. agent.stats.retried .. " 次）")
  check(agent.stats.by_ai == 0, "这个 mock 从没给出合法输出，不该记成 AI 决策")
  check(agent.stats.by_fallback == nil,
    "旧的『回落规则 BOT』统计应已彻底移除")

  -- 没配传输层：机械应答，且不进入思考状态
  local room2 = makeRoom(6, { 1 })
  local bare = Agent.create({})
  local st, _ = Driver.create(room2, Bot.make(), bare):advance()
  check(st ~= "thinking", "未配置传输层时不应进入思考状态")
end

do
  -- 第一次输出不合法、第二次合法：重试应该把它救回来
  local room = makeRoom(9, { 1 })
  local calls = 0
  local agent = Agent.create({
    transport = Transport.mock {
      responder = function()
        calls = calls + 1
        if calls == 1 then return "我选择第一个动作" end -- 故意的：没有 JSON
        return '{"action":1,"reason":"重试后成功"}'
      end,
    },
    retries = 1,
  })
  local driver = Driver.create(room, Bot.make(), agent)
  local guard = 0
  -- 一直推进到「重试后的结果真的被采用」为止：只等 retried>0 不行，
  -- 那一刻重试的响应还在路上，by_ai 仍是 0
  while agent.stats.by_ai == 0 and not room.game_over and guard < 5000 do
    guard = guard + 1
    local st, req = driver:advance()
    if st == "over" then break end
    if st == "thinking" then
      local r, s = agent:respond(req, room)
      if s == "ready" then room:step(r) end
    elseif st == "human" then
      room:step(Bot.make()(req, room))
    end
  end
  check(agent.stats.retried > 0, "第一次解析失败应触发重试")
  check(agent.stats.by_ai > 0, "重试后的合法输出应被采用")
end

do
  -- 异步路径：mock 故意拖 3 拍，验证真的会返回 thinking 而不是阻塞等
  local room = makeRoom(9, { 1 })
  local agent = Agent.create({
    transport = Transport.mock { delay = 3, responder = function() return '{"action":1}' end },
  })
  local req = advanceToRequest(room, agent, "askForUseCard")
  if req then
    local _, s1 = agent:respond(req, room)
    local _, s2 = agent:respond(req, room)
    local _, s3 = agent:respond(req, room)
    local _, s4 = agent:respond(req, room)
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
      for _ = 1, r.n do
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
print("--- Responses 协议（hy3）---")

do
  local Json = require "src.core.json"
  -- 请求体：instructions + input，而不是 messages
  local d = Json.decode(Transport.buildBody({
    protocol = "responses", model = "hy3", reasoning_effort = "none",
  }, { system = "你是玩家", user = "请选择" }))
  check(d.model == "hy3" and d.instructions == "你是玩家" and d.input == "请选择",
    "responses 请求体应是 instructions + input")
  check(d.stream == false, "应使用同步模式")
  check(d.reasoning and d.reasoning.effort == "none",
    "必须显式把思维链关掉（hy3 默认 high，单次要 10 秒以上）")

  -- 不给 effort 时不该凭空造一个 reasoning 字段
  local d0 = Json.decode(Transport.buildBody({
    protocol = "responses", model = "hy3",
  }, { system = "s", user = "u" }))
  check(d0.reasoning == nil, "没配 effort 就不该带 reasoning 字段")

  -- chat 协议不受影响
  local d2 = Json.decode(Transport.buildBody({
    protocol = "chat", model = "m", temperature = 0.2, max_tokens = 50,
  }, { system = "S", user = "U" }))
  check(d2.messages and #d2.messages == 2 and d2.instructions == nil,
    "chat 请求体应仍是 messages 数组")

  -- 解析：优先 output_text
  local r1 = Transport.parseResponse(
    '{"status":"completed","output_text":"{\\"action\\":1}"}', "responses")
  check(r1.ok and r1.text:find("action") ~= nil, "应能取到顶层 output_text")

  -- 没有 output_text 时从 output 数组里拼，并带出思维链摘要
  local r2 = Transport.parseResponse(
    '{"output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"我想了想"}]},'
    .. '{"type":"message","content":[{"type":"output_text","text":"答案"}]}]}', "responses")
  check(r2.ok and r2.text == "答案", "没有 output_text 时应从 output 数组里取")
  check(r2.reasoning == "我想了想", "应能取出思维链摘要（调试用）")

  local r3 = Transport.parseResponse('{"error":{"message":"bad key"}}', "responses")
  check(r3.ok == false and r3.err:find("bad key") ~= nil, "接口报错应带回原因")
  check(Transport.parseResponse('{"status":"incomplete"}', "responses").ok == false,
    "没有正文应判为失败")

  -- 协议推断
  check(Transport.guessProtocol("https://llm.example.com/v1/responses")
    == "responses", "URL 含 /responses 应识别为 Responses 协议")
  check(Transport.guessProtocol("https://api.openai.com/v1/chat/completions")
    == "chat", "URL 含 /chat/completions 应识别为 chat 协议")
  check(Transport.curl { url = "https://x/v1/responses" }.protocol == "responses",
    "Curl 构造时应自动推断协议")
end

print()
print("--- 代理模式：明文连本机服务（真 socket 端到端）---")

-- 一个极简的假 LLM 服务端，跑在单独的线程里。
-- 为什么要用线程：http.request 是同步的，服务端和客户端在同一个 Lua 状态里
-- 会互相等死（accept 等连接、request 等响应）。
local MOCK_SERVER = [[
local port = ...
local ok, socket = pcall(require, "socket")
if not ok then return end
local srv = socket.bind("127.0.0.1", port)
if not srv then return end
srv:settimeout(10)
-- 循环 accept：只服务一个真实请求，空连接（连上就关的那种）跳过
local done, tries = false, 0
while not done and tries < 20 do
  tries = tries + 1
  local c = srv:accept()
  if c then
    c:settimeout(3)
    local line = c:receive("*l")
    if not line then
      c:close()   -- 探测连接，什么都没发
    else
      local len = 0
      while true do
        local l = c:receive("*l")
        if not l or l == "" then break end
        local n = l:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if n then len = tonumber(n) end
      end
      if len > 0 then c:receive(len) end
      local out = '{"choices":[{"message":{"content":"{\\"action\\":1,\\"reason\\":\\"ok\\"}"}}]}'
      c:send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
        .. #out .. "\r\nConnection: close\r\n\r\n" .. out)
      c:close()
      done = true
    end
  end
end
srv:close()
]]

local function startMockServer(port)
  local ok, th = pcall(function() return love.thread.newThread(MOCK_SERVER) end)
  if not ok then return nil end
  th:start(port)
  love.timer.sleep(0.5)  -- 等它 listen 起来，否则客户端连的是还没监听的端口
  return th
end

do
  local PORT = 18923
  local server = startMockServer(PORT)

  local p = Transport.proxy { url = "http://127.0.0.1:" .. PORT, timeout = 5 }
  local res = p:request({ system = "S", user = "U" })
  check(res.ok == true, "明文连本机代理应成功"
    .. (res.ok and "" or ("：" .. tostring(res.err))))
  check(res.ok and res.text:find('"action"') ~= nil,
    "应拿到模型输出的 JSON（实得 " .. tostring(res.text) .. "）")

  -- 代理不在时应报错而不是抛异常——否则一次网络抖动就崩游戏
  local dead = Transport.proxy { url = "http://127.0.0.1:1", timeout = 2 }
  local bad = dead:request({ system = "S", user = "U" })
  check(bad.ok == false, "代理不可达时应返回失败" .. (bad.ok and "（却成功了）" or ""))
  check(type(bad.err) == "string" and bad.err ~= "",
    "失败时应带上原因（实得 " .. tostring(bad.err) .. "）")

  if server then server:wait() end
end

do
  -- UI 实际走的路径：线程版 transport 的 socket 模式
  local ok_mod, mod = pcall(require, "src.ui.ai_transport")
  if not ok_mod then
    print("SKIP  无法加载 ui 传输层，跳过线程版用例")
  else
    local PORT = 18924
    local server = startMockServer(PORT)
    local th = mod.Threaded.create({
      mode = "socket",
      url = "http://127.0.0.1:" .. PORT .. "/v1/chat/completions",
      timeout = 5,
    })
    check(th.mode == "socket", "线程版应支持 socket 模式")
    th:submit({ system = "S", user = "U" })
    local res = nil
    for _ = 1, 100 do
      res = th:poll()
      if res then break end
      love.timer.sleep(0.05)
    end
    check(res ~= nil, "线程版 socket 模式应能拿回结果")
    check(res and res.ok and res.text:find('"action"') ~= nil,
      "线程版拿到的内容应正确（实得 " .. tostring(res and res.text) .. "）")
    check(th.thread:getError() == nil,
      "线程不应报错（实得 " .. tostring(th.thread:getError()) .. "）")
    if server then server:wait() end
  end
end

print()
print("--- 跨步骤记忆 ---")

do
  local Memory = require "src.core.ai.memory"
  local mem = Memory.create({ max_steps = 3 })

  check(mem:render() and mem:render():find("第一步") ~= nil,
    "空记忆应说明这是第一步")

  for i = 1, 5 do
    mem:record({ turn = i, stage = "出牌",
      choice = "使用【杀】→P" .. i, reason = "理由" .. i })
  end
  local text = mem:render()
  check(mem.total == 5, "总步数应是 5（实得 " .. mem.total .. "）")
  check(mem:stepCount() == 3, "只保留最近 3 步（实得 " .. mem:stepCount() .. "）")
  check(text:find("最早的 2 步已折叠") ~= nil, "应提示折叠了多少步")
  check(text:find("理由5") ~= nil, "最近一步的理由应保留")
  check(text:find("理由1") == nil, "被折叠的步骤不该再出现")
  check(text:find("更早") ~= nil, "折叠部分应有摘要行")
end

do
  -- 身份判断：模型可能写座位号 / P2 / 座位2 / 玩家名，都要能认出来
  local Memory = require "src.core.ai.memory"
  local mem = Memory.create({})
  local names = { [1] = "甲", [2] = "乙", [3] = "丙" }
  local function nameOf(k)
    local s = tostring(k)
    local n = s:match("^%d+$") or s:match("^[Pp](%d+)$") or s:match("座位(%d+)")
    if n then return names[tonumber(n)] end
    for _, v in pairs(names) do if v == s then return v end end
    return nil
  end

  mem:updateBeliefs({ ["P2"] = "反贼", ["座位3"] = "主公", ["甲"] = "忠臣" }, nameOf)
  check(mem.beliefs["乙"] == "反贼", "「P2」应归一成玩家名「乙」")
  check(mem.beliefs["丙"] == "主公", "「座位3」应归一成「丙」")
  check(mem.beliefs["甲"] == "忠臣", "直接用玩家名也应接受")

  -- 脏输入不该污染记忆
  mem:updateBeliefs({ ["乙"] = "我看大概率是反贼" }, nameOf)
  check(mem.beliefs["乙"] == "反贼", "长句里的关键字应被提取")
  mem:updateBeliefs({ ["查无此人"] = "反贼" }, nameOf)
  check(mem.beliefs["查无此人"] == nil, "不认识的玩家名应被忽略")
  mem:updateBeliefs({ ["丙"] = "一种说不清的东西" }, nameOf)
  check(mem.beliefs["丙"] == "主公", "无法识别的标签不该覆盖已有判断")

  check(mem:render(nameOf):find("乙：反贼") ~= nil, "渲染里应包含身份判断")
end

do
  -- 端到端：LLM 回传 beliefs/note → Agent 落库 → 下次提示词里带上
  local room = makeRoom(11, { 1 })
  local agent = Agent.create({
    transport = Transport.mock {
      responder = function()
        return '{"action":1,"reason":"试探主公","beliefs":{"P2":"反贼","P3":"主公"},"note":"P2 先手打我"}'
      end,
    },
  })
  local driver = Driver.create(room, Bot.make(), agent)
  local guard = 0
  while (agent.stats.by_ai < 3) and not room.game_over and guard < 5000 do
    guard = guard + 1
    local st, req = driver:advance()
    if st == "over" then break end
    if st == "thinking" then
      local r, s = agent:respond(req, room)
      if s == "ready" then room:step(r) end
    elseif st == "human" then
      room:step(Bot.make()(req, room))
    end
  end

  local mem = agent.memories[1]
  check(mem ~= nil, "Agent 应为 AI 座位建立记忆")
  check(mem and mem.total >= 3, "记忆里应记下走过的步骤（实得 "
    .. tostring(mem and mem.total) .. "）")
  check(mem and mem.beliefs["P2"] == "反贼", "LLM 回传的身份判断应落库")
  check(mem and mem.beliefs["P3"] == "主公", "多人的身份判断都应落库")
  check(mem and mem.notes == "P2 先手打我", "长期观察应落库")

  -- 提示词里必须真的带上决策史，否则记忆等于没做
  local calls = agent.transport.calls
  local last = calls[#calls]
  check(last ~= nil, "应记录下每次提交的提示词")
  if last then
    check(last.user:find("你的决策史", 1, true) ~= nil, "提示词应包含决策史段落")
    check(last.user:find("你上次对各自身份的判断", 1, true) ~= nil,
      "提示词应包含上次的身份判断")
    check(last.user:find("试探主公", 1, true) ~= nil,
      "记忆里应能看到自己上次给的理由")
  end
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

print()
print("--- AI 思考与身份猜测过程 ---")

do -- belief_log：判断变化要留痕（UI 的时间线就靠它）
  local Memory = require "src.core.ai.memory"
  local mem = Memory.create({})
  mem:updateBeliefs({ ["乙"] = "反贼" }, function(k) return k end, { turn = 2, reason = "他杀主公" })
  mem:updateBeliefs({ ["乙"] = "反贼" }, function(k) return k end, { turn = 3, reason = "重复判断" })
  mem:updateBeliefs({ ["乙"] = "内奸" }, function(k) return k end, { turn = 5, reason = "他救了主公" })
  local log = mem:beliefTimeline()
  check(#log == 2, "重复同值不应记录，变化才记（实得 " .. #log .. " 条）")
  check(log[1].from == "未知" and log[1].to == "反贼" and log[1].turn == 2,
    "首次判断应记 未知→反贼（实得 " .. log[1].from .. "→" .. log[1].to .. "）")
  check(log[2].from == "反贼" and log[2].to == "内奸" and log[2].turn == 5,
    "改判应记 反贼→内奸")
  check(log[2].reason == "他救了主公", "时间线应带上当次理由")

  local changes = mem:updateBeliefs({ ["乙"] = "内奸" }, function(k) return k end)
  check(type(changes) == "table" and #changes == 0, "无变化时应返回空表")
end

do -- 端到端：beliefs 变化触发 on_beliefs；reasoning 摘要触发 on_reasoning
  local room = makeRoom(12, { 1 })
  local belief_events, reasoning_events = {}, {}
  local first = true
  local agent = Agent.create({
    transport = Transport.mock {
      responder = function()
        if first then
          first = false
          return { text = '{"action":1,"reason":"试探","beliefs":{"P2":"反贼"}}',
            reasoning = "P2 对主公出杀，应是反贼" }
        end
        return '{"action":1,"reason":"继续"}'
      end,
    },
    on_beliefs = function(changes, ctx)
      belief_events[#belief_events + 1] = { changes = changes, ctx = ctx }
    end,
    on_reasoning = function(who, summary)
      reasoning_events[#reasoning_events + 1] = { who = who, summary = summary }
    end,
  })
  local driver = Driver.create(room, Bot.make(), agent)
  local guard = 0
  while (agent.stats.by_ai < 2) and not room.game_over and guard < 5000 do
    guard = guard + 1
    local st, req = driver:advance()
    if st == "over" then break end
    if st == "thinking" then
      local r, s = agent:respond(req, room)
      if s == "ready" then room:step(r) end
    elseif st == "human" then
      room:step(Bot.make()(req, room))
    end
  end
  check(#belief_events == 1, "首次给出判断应触发一次 on_beliefs（实得 "
    .. #belief_events .. " 次）")
  if belief_events[1] then
    local c = belief_events[1].changes[1]
    check(c and c.to == "反贼" and c.from == "未知",
      "on_beliefs 应带 未知→反贼 的变化（实得 "
        .. tostring(c and (c.from .. "→" .. c.to)) .. "）")
    check(belief_events[1].ctx.reason == "试探", "ctx 应带当次决策理由")
  end
  check(#reasoning_events == 1 and reasoning_events[1].summary == "P2 对主公出杀，应是反贼",
    "思维链摘要应透传到 on_reasoning（实得 " .. #reasoning_events .. " 次）")
  -- 第二次起不再回传 beliefs，也不再有 reasoning：不应重复触发
  check(#belief_events == 1 and #reasoning_events == 1, "无变化/无摘要时不应触发回调")
end

print(string.format("\n===== AI 测试: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("AI 测试失败", 0) end
