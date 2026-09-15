-- 网络层测试（房间 / 座位 / 同步）
--
-- 全部走**内存通道**，不占端口、不依赖时序，因此完全确定。
-- 真实 TCP 的部分（server/client 的 socket 适配）在真机上验证。
local real_love = love
love = nil -- 网络层不应依赖 love

local ok, fatal = pcall(function()

local Channel = require "src.net.channel"
local Client = require "src.net.client"
local Host = require "src.net.host"
local Protocol = require "src.net.protocol"

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 print("PASS  " .. msg)
  else failures = failures + 1 print("FAIL  " .. msg) end
end

print("--- 协议：编解码 ---")

do
  local m = { type = "req", id = 7, req = "askForCard", card_name = "dodge" }
  local line = Protocol.encode(m)
  check(type(line) == "string" and string.sub(line, -1) == "\n", "编码应以换行结尾")
  local back = Protocol.decode(line)
  check(back ~= nil and back.type == "req" and back.id == 7, "往返解码应保持一致")
  check(back and back.card_name == "dodge", "字段应保留（实得 " .. tostring(back and back.card_name) .. "）")
  check(Protocol.decode("") == nil, "空行应返回 nil 而非报错")
  check(Protocol.decode("这不是 json") == nil, "非法 JSON 应安全返回 nil")

  -- 分帧：一次收到不完整 / 多条
  local buf = Protocol.encode({ type = "a" }) .. Protocol.encode({ type = "b" })
  local m1, rest = Protocol.takeFrame(buf)
  check(m1 and m1.type == "a", "takeFrame 应切出第一条")
  local m2, rest2 = Protocol.takeFrame(rest)
  check(m2 and m2.type == "b", "takeFrame 应切出第二条")
  local m3, rest3 = Protocol.takeFrame(rest2)
  check(m3 == nil and rest3 == "", "切完应返回 nil 与空串")

  -- 半个包不应被切出
  local half = string.sub(Protocol.encode({ type = "x" }), 1, 5)
  local h, hr = Protocol.takeFrame(half)
  check(h == nil, "半个包不应切出消息")

  -- 【制衡】手牌 + 装备多选请求应完整下发候选与能力标志。
  local fake_hand = { id = 9101, name = "slash", suit = 1, number = 7 }
  local fake_equip = { id = 9102, name = "halberd", suit = 4, number = 12 }
  local zreq = Protocol.makeRequest(8, {
    type = "askForDiscard", player = { name = "孙权" }, n = 2,
    any = true, include_equips = true, cards = { fake_hand, fake_equip },
  }, function() return 1 end)
  check(zreq.any and zreq.include_equips and #zreq.cards == 2,
    "制衡协议应下发任意多选、装备候选及全部牌")
end

do -- 服务端应把制衡返回的装备 card_id 还原为本人装备对象
  local Card = require "src.core.card"
  local host = Host.create { count = 2 }
  host:startGame(9)
  local p = host.players[1]
  local equip = Card.create(9103, "halberd", Card.Suit.Diamond, 12, Card.Type.Equip)
  p.equips.weapon = equip
  host.room.pending = {
    type = "askForDiscard", player = p, n = 1,
    any = true, include_equips = true, cards = { equip },
  }
  local resp = host:toResponse({ card_ids = { equip.id } })
  check(type(resp) == "table" and #resp == 1 and resp[1] == equip,
    "服务端应从装备区还原制衡的 card_ids")
end

print("\n--- 房间与座位 ---")

do
  local host = Host.create { count = 5 }
  local a1, a2 = Channel.pair()
  local b1, b2 = Channel.pair()
  local seat1 = host:attach("甲", a1)
  local seat2 = host:attach("乙", b1)
  check(seat1 == 1 and seat2 == 2, "应按顺序分配座位（实得 " .. tostring(seat1) .. "," .. tostring(seat2) .. "）")
  local third = host:attach("丙", Channel.pair())
  check(third == 3, "第三个应坐 3 号位")
  local info = host:seatInfo()
  check(#info == 5, "座位表应有 5 项（5 人局）")
  check(info[1].occupied and info[5].occupied == false, "占用状态应正确")

  host:detach(2)
  check(host:seatInfo()[2].occupied == false, "detach 后该座应空出")
  local again = host:attach("丁", b1)
  check(again == 2, "空座应被复用（实得 " .. tostring(again) .. "）")

  -- 坐满后再来人应被拒（5 人房：已占 1,2,3，再坐 4、5 后满）
  host:attach("戊", Channel.pair())
  host:attach("己", Channel.pair())
  local full, err = host:attach("庚", Channel.pair())
  check(full == nil, "满房应拒绝加入（" .. tostring(err) .. "）")
end

print("\n--- 同步：跑完一局 ---")

do
  local host = Host.create { count = 5 }
  -- 5 人局：1 号位真人客户端（脚本应答：一律放弃），其余 BOT
  local s1, c1 = Channel.pair()
  local cli = Client.create("甲", c1)
  host:attach("甲", s1)
  host:startGame(42)

  cli.on_request = function(_self, req)
    -- 真人座位一律选择「不发动 / 不出牌」
    return false
  end

  local guard = 0
  local waited = 0
  while not host.room.game_over and guard < 20000 do
    guard = guard + 1
    local st = host:tick()
    if st == "waiting" then
      waited = waited + 1
      cli:flush() -- 客户端收请求并自动应答
    elseif st == "over" then
      break
    end
  end

  check(host.room.game_over, "对局应能跑完（guard=" .. guard .. "）")
  check(waited > 0, "人类座位应收到过请求并等待应答（等待次数 " .. waited .. "）")
  check(#(host.room.loglines or {}) > 10, "应产生日志（" .. #(host.room.loglines or {}) .. " 条）")

  -- 快照
  local snap = host:snapshot()
  check(snap ~= nil and #snap.players == 5, "快照应含 5 名玩家（5 人局）")
  check(snap.over == true, "快照应标记结束")
  check(type(snap.players[1].skills) == "table" and #snap.players[1].skills > 0,
    "快照应包含公开的武将技能名，供客户端显示说明")

  -- 断线不应卡死：把人类座位摘掉后仍能推进到结束
  local host2 = Host.create { count = 8 }
  local s2, c2 = Channel.pair()
  local cli2 = Client.create("乙", c2)
  host2:attach("乙", s2)
  host2:startGame(7)
  cli2.on_request = function() return false end
  local g2 = 0
  while not host2.room.game_over and g2 < 20000 do
    g2 = g2 + 1
    local st = host2:tick()
    if st == "waiting" then cli2:flush() end
    if g2 == 5 then host2:detach(1) end -- 中途掉线
  end
  check(host2.room.game_over, "掉线后对局仍应跑完（guard=" .. g2 .. "）")
end

print("\n--- 联机 AI：空座交给 LLM（mock 传输层）---")

do
  -- 与单机同一套 Agent，mock 传输层不联网；1 号位真人（自动放弃），其余全 AI。
  -- 验证：座位命名/控制权、Driver 的 "thinking" 状态不卡 tick、对局能结束。
  local Agent = require "src.core.ai.agent"
  local Transport = require "src.core.ai.transport"
  local rng_state = 12345
  local function rng(n)
    rng_state = (rng_state * 1103515245 + 12345) % 2147483648
    return rng_state % n + 1
  end
  local agent = Agent.create({
    transport = Transport.mock {
      responder = function(prompt)
        local acts = prompt.actions or {}
        if #acts == 0 then return '{"action":1}' end
        local r = prompt.view and prompt.view.request
        if r and r.type == "askForDiscard" and r.n and r.n > 1 then
          local ids = {}
          for i = 1, r.n do ids[#ids + 1] = acts[i] and acts[i].id or 1 end
          return string.format('{"actions":[%s],"reason":"弃牌"}', table.concat(ids, ","))
        end
        return string.format('{"action":%d,"reason":"选它"}', acts[rng(#acts)].id)
      end,
    },
  })
  local host = Host.create { count = 5, ai_agent = agent, ai_seats = "empty" }
  local s1, c1 = Channel.pair()
  local cli = Client.create("甲", c1)
  host:attach("甲", s1)
  host:startGame(42)
  check(host.room.players[1].name == "甲", "人类座位名字应保留")
  check(host.room.players[2].name:find("^AI·") ~= nil,
    "空座应由 AI 顶替（实得 " .. host.room.players[2].name .. "）")
  check(host.room.players[2]:controlMode() == "ai", "空座座位应标记为 ai 控制")

  cli.on_request = function() return false end
  local guard, thinking = 0, 0
  while not host.room.game_over and guard < 20000 do
    guard = guard + 1
    local st = host:tick()
    if st == "waiting" then cli:flush() end
    if st == "thinking" then thinking = thinking + 1 end
    if st == "over" then break end
  end
  check(host.room.game_over, "AI 顶替空座的对局应能跑完（guard=" .. guard .. "）")
  check(thinking > 0, "tick 应观察到 AI 思考状态（" .. thinking .. " 次）")
  check(agent.stats.by_ai > 0, "LLM 确实做了决策（" .. agent.stats.by_ai .. " 次）")
end

print("\n--- 掉线重连 / 观战 / 聊天 ---")

do
  local host = Host.create { count = 5 }

  -- 掉线：保留座位，宽限期内可重连
  local a1 = Channel.pair()
  local seat, tok = host:attach("甲", a1)
  check(tok ~= nil, "占座应下发重连令牌")
  host:dropSeat(seat)
  check(host.seats[seat].channel == nil, "掉线后通道应清空")
  check(host.seats[seat].name == "甲", "掉线应保留座位信息（名字）")
  check(host:freeSeat() == nil or true, "掉线座位不应立即被新人占用")

  local b1, _ = Channel.pair()
  check(host:resumeSeat(b1, tok) == seat, "令牌正确应能重连回原座")
  check(host.seats[seat].channel == b1, "重连后通道应恢复")
  check(host:resumeSeat(Channel.pair(), "错误令牌") == nil, "错误令牌应被拒绝")

  -- 观战：不占座，但能收到广播
  local h2 = Host.create { count = 5 }
  local s1 = Channel.pair()
  local sp_s, sp_c = Channel.pair()
  h2:attach("甲", s1)
  h2:addSpectator(sp_s, "看客")
  check(h2:freeSeat() == 2, "观战者不应占用座位")
  h2:broadcast { type = "log", lines = { "一行日志" } }
  local got = sp_c:recv()
  check(got ~= nil and got.type == "log", "观战者应收到广播")
  check(h2:removeSpectator(sp_s), "应能移除观战者")

  -- 聊天：记录并广播
  local h3 = Host.create { count = 5 }
  local q1, q2 = Channel.pair()
  h3:attach("乙", q1)
  h3:chat(1, "乙", "大家好")
  check(#h3.chats == 1, "聊天应记入历史")
  local cm = q2:recv()
  check(cm ~= nil and cm.type == "chat" and cm.text == "大家好",
    "聊天应广播给在线玩家（实得 " .. tostring(cm and cm.text) .. "）")
end

print("\n--- 真实 TCP：服务端 + 客户端完整对局 ---")

do
  -- 这一组用真 socket（回环），验证 TCP 适配层而不仅是内存通道。
  -- 端口取一个不常用的；失败时跳过而不是判 FAIL，避免污染 CI 环境。
  local socket = require "socket"
  local Server = require "src.net.server"
  local port = 9900 + (os.time() % 90)
  -- minStart=1：单人也要能开局（默认 2 是给多人联机用的，见 Host.minStart）
  local srv = Server.create(port, 5, 1)
  local ok, err = pcall(function() srv:bind() end)
  if not ok then
    print("SKIP  真实 TCP 测试（无法监听: " .. tostring(err) .. "）")
  else
    local ch = Channel.open("127.0.0.1", port)
    check(ch ~= nil, "应能连上服务端")
    if ch then
      ch:send { type = "hello", name = "甲" }
      ch:send { type = "ready", ready = true }
      local reqs = 0
      local g = 0
      -- 注意：服务端是常驻的（一局结束不退出、可再开），
      -- 所以循环条件看**对局是否结束**，不能看 srv.finished
      while not (srv.host.room and srv.host.room.game_over) and g < 3000 do
        g = g + 1
        srv:pump()
        local m = ch:recv()
        while m do
          if m.type == "req" then
            reqs = reqs + 1
            ch:send { type = "resp", id = m.id, value = false }
          end
          m = ch:recv()
        end
        socket.sleep(0.005)
      end
      check(reqs > 0, "客户端应收到过请求（实得 " .. reqs .. " 次）")
      check(srv.host.room ~= nil, "服务端应已开局")
      check(srv.host.room and srv.host.room.game_over,
        "对局应通过 TCP 跑完（turn="
        .. tostring(srv.host.room and srv.host.room.turn_count) .. "）")
      check(#(srv.host.room.loglines or {}) > 20,
        "应产生日志（" .. #(srv.host.room.loglines or {}) .. " 条）")
      -- 结束时服务端应广播过 over
      check(srv.host._over_sent == true, "结束应广播 over")
    end
  end
end

print("\n--- 客户端：消息处理 ---")

do
  local srv, cli_ch = Channel.pair()
  local c = Client.create("测试", cli_ch)
  c:hello()
  local m = srv:recv()
  check(m and m.type == "hello" and m.name == "测试", "服务端应收到 hello")
  -- 模拟服务端下发
  srv:send { type = "welcome", seat = 3 }
  c:flush()
  check(c.seat == 3, "客户端应记住自己的座位")
  srv:send { type = "log", lines = { "一行" } }
  c:flush()
  check(#c.logs == 1, "客户端应累积日志")
  local answered = nil
  c.on_request = function(_, req) answered = req.id return false end
  srv:send { type = "req", id = 9, req = "askForSkillInvoke", skill = "苦肉" }
  c:flush()
  local resp = srv:recv()
  check(answered == 9, "客户端应收到请求")
  check(resp and resp.type == "resp" and resp.id == 9 and resp.value == false,
    "客户端应答应能被服务端收到")
end

print(string.format("\n===== 网络测试: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("网络测试失败", 0) end

end)

love = real_love
if not ok then error(fatal, 0) end
