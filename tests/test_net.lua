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

print("\n--- 真实 TCP：服务端 + 客户端完整对局 ---")

do
  -- 这一组用真 socket（回环），验证 TCP 适配层而不仅是内存通道。
  -- 端口取一个不常用的；失败时跳过而不是判 FAIL，避免污染 CI 环境。
  local socket = require "socket"
  local Server = require "src.net.server"
  local port = 9900 + (os.time() % 90)
  local srv = Server.create(port, 5)
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
      while not srv.finished and g < 3000 do
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
  c.on_request = function(_self, req) answered = req.id return false end
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
