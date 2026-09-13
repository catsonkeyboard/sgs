-- headless 对局测试：AI vs AI 完整迷你局 + 多种子回归 + 卡牌守恒校验
-- 运行: love . --test （conf.lua 检测 --test 关闭窗口）
-- 也可用任意 Lua 5.1/LuaJIT 直接运行: lua tests/test_game.lua
if not pcall(require, "love.filesystem") then
  package.path = "./?.lua;" .. package.path
end

local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local AI = require "src.core.ai"

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

local function playGame(seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local p2 = Player.create("乙", engine:getGeneral("剑阁武将"), 2, false)
  local room = Room.create(engine, { p1, p2 })
  room.drawPile = Standard.buildDrawPile(seed)
  room:start()
  local driver = Driver.create(room, AI.makeAI())
  driver:advance()
  return room
end

-- 1) 单局完整性
local room = playGame(42)
check(room.game_over, "游戏应正常结束")
check(room.winner ~= nil, "应有胜者")
check(room.winner.alive, "胜者应存活")
check(#room.loglines > 10, "对局日志完整（" .. #room.loglines .. " 条）")
check(room.turn_count <= Room.MAX_TURNS, "回合数在保险线内（" .. room.turn_count .. "）")

-- 2) 卡牌守恒：初始 29 张 = 摸牌堆 + 弃牌堆 + 所有玩家手牌
local total = #room.drawPile + #room.discardPile
for _, p in ipairs(room.players) do
  total = total + #p.hand
end
check(total == 29, "卡牌守恒 29 == " .. total)

-- 3) 多种子回归（覆盖出杀/闪避/伤害/濒死/吃桃/弃牌等路径）
local ok_seeds, bad_seeds = 0, {}
for seed = 1, 30 do
  local ok = pcall(function()
    local r = playGame(seed)
    assert(r.game_over and r.winner ~= nil, "未正常结束")
    assert(r.turn_count <= Room.MAX_TURNS, "超回合")
  end)
  if ok then ok_seeds = ok_seeds + 1 else table.insert(bad_seeds, seed) end
end
check(ok_seeds == 30, "30 个种子全部跑通（失败: " .. table.concat(bad_seeds, ",") .. "）")

print(string.format("\n===== %d passed, %d failed =====", passes, failures))
if failures > 0 then os.exit(1) end
