-- 压力测试：大批量种子跑完整对局，验证不会死锁 / 丢牌 / 抛异常
-- 与常规单测分开，因为耗时较长。
-- 运行: love . --soak
if not pcall(require, "love.filesystem") then
  package.path = "./?.lua;" .. package.path
end

local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local AI = require "src.core.ai"

local N = 25 -- 每种模式跑多少个种子

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 print("PASS  " .. msg)
  else failures = failures + 1 print("FAIL  " .. msg) end
end

local function totalCards(room)
  local n = #room.drawPile + #room.discardPile
  for _, p in ipairs(room.players) do n = n + p:allCardCount() end
  return n
end

local function runGame(build)
  local ok, err = pcall(function()
    local r = build()
    r:start()
    local d = Driver.create(r, AI.makeAI())
    d:advance()
    assert(r.game_over, "对局未结束")
    assert(r.turn_count <= Room.MAX_TURNS, "超过最大回合数")
    assert(totalCards(r) == Standard.deckSize(),
      "卡牌不守恒: " .. totalCards(r) .. " != " .. Standard.deckSize())
    if r.identity_mode then
      assert(r.win_role ~= nil, "身份局未判定获胜阵营")
    end
  end)
  return ok, err
end

local function makeDuel(seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local p2 = Player.create("乙", engine:getGeneral("剑阁武将"), 2, false)
  local r = Room.create(engine, { p1, p2 })
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  return r
end

local function makeIdentity(seed, n)
  local engine = Engine.create()
  Standard.setup(engine)
  local generals = { "张飞", "曹操", "司马懿", "华佗" }
  local ps = {}
  for i = 1, n do
    local g = engine:getGeneral(generals[((i - 1) % 4) + 1]) or engine:getGeneral("白板武将")
    table.insert(ps, Player.create("P" .. i, g, i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  r:setupRoles(Standard.makeRng(seed + 1))
  return r
end

print(string.format("== 压力测试：每种模式 %d 个种子 ==", N))

local function soak(label, builder)
  local bad = {}
  for seed = 1, N do
    local ok, err = runGame(function() return builder(seed) end)
    if not ok then
      table.insert(bad, seed .. ":" .. tostring(err))
    end
  end
  check(#bad == 0, label .. " " .. N .. " 局全部通过"
    .. (#bad == 0 and "" or "（失败: " .. table.concat(bad, " | ") .. "）"))
end

soak("1v1 标准局", makeDuel)
soak("4 人身份局", function(seed) return makeIdentity(seed, 4) end)
soak("5 人身份局", function(seed) return makeIdentity(seed, 5) end)
soak("8 人身份局", function(seed) return makeIdentity(seed, 8) end)

print(string.format("\n===== 压力测试: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("压力测试失败", 0) end
