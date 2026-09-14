-- UI 布局回归测试：不需要图形环境，把 love.graphics 打桩后直接验证命中测试。
--
-- 这个测试守护的正是 A0.2/A0.3 误判为「LuaJIT 编译器错误」的那个 bug：
-- scene_room.lua 用 self.handCardRect(i) 点号调用冒号定义的 handCardRect，
-- 导致实参 i 被绑定到隐式 self、形参 i 收到 nil。
-- 表现是「点牌崩溃」，根因却是调用语法。此处直接断言命中测试的分派结果。
local real_love = love

local ok, fatal = pcall(function()

-- 打桩 love.graphics（core/ 不依赖 love，只有 ui 层用）
local stub_font = setmetatable({}, { __call = function() end, __index = function() return function() end end })
love = {
  graphics = {
    newFont = function() return stub_font end,
    setFont = function() end,
    setColor = function() end,
    clear = function() end,
    print = function() end,
    printf = function() end,
    rectangle = function() end,
    circle = function() end,
    getDimensions = function() return 1130, 650 end,
  },
}

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 print("PASS  " .. msg)
  else failures = failures + 1 print("FAIL  " .. msg) end
end

package.loaded["src.ui.scene_room"] = nil
local RoomScene = require "src.ui.scene_room"

-- 构造场景（init 会真实跑一局引擎初始化与 BOT 推进）
local scene = RoomScene.create(function() end)

check(scene.human ~= nil, "场景应创建人类玩家")
check(#scene.human.hand > 0, "人类玩家应有起始手牌（" .. #scene.human.hand .. " 张）")

-- handCardRect 冒号调用应返回递增量 x
local x1 = scene:handCardRect(1)
local x2 = scene:handCardRect(2)
check(type(x1) == "number", "handCardRect(1) 应返回数字 x（得到 " .. type(x1) .. "）")
check(x2 > x1, "handCardRect(2) 的 x 应大于 handCardRect(1)")

-- 命中测试：点每张牌中心都应命中自身
local CARD_W, CARD_H = 62, 86
local bad = {}
for idx = 1, #scene.human.hand do
  local cx, cy = scene:handCardRect(idx)
  local card, got = scene:cardAt(cx + CARD_W / 2, cy + CARD_H / 2)
  if not (got == idx and card == scene.human.hand[idx]) then
    table.insert(bad, string.format("期望%d得到%s", idx, tostring(got)))
  end
end
check(#bad == 0, "点击每张手牌中心都应命中自身"
  .. (#bad == 0 and "（全部命中）" or "（" .. table.concat(bad, ",") .. "）"))

-- 空白处不应命中
local miss_card, miss_idx = scene:cardAt(5, 5)
check(miss_card == nil and miss_idx == nil, "点击空白处不应命中任何手牌")

-- draw / mousepressed 不应抛错（覆盖渲染与点击路径）
local ok_draw, err_draw = pcall(function() scene:draw() end)
check(ok_draw, "draw() 应无异常" .. (ok_draw and "" or ("：" .. tostring(err_draw))))
local ok_mp, err_mp = pcall(function() scene:mousepressed(5, 5, 1) end)
check(ok_mp, "mousepressed() 在空白处应无异常" .. (ok_mp and "" or ("：" .. tostring(err_mp))))

-- 皮肤/卡图接线：场景应持有 skin，且缺图时必须安全降级
check(scene.skin ~= nil, "场景应持有 Skin 实例")
check(type(scene.cardImages) == "table", "场景应有卡图缓存")
local ok_img, err_img = pcall(function() scene:draw() end)
check(ok_img, "接入卡图后 draw() 仍应无异常"
  .. (ok_img and "" or ("：" .. tostring(err_img))))

-- anchorOf / panelAt：曾因「同一份文件里 anchorOf 定义了两次」而崩溃。
-- 一份返回两个数字、一份返回 {x,y} 表，后者覆盖前者，panelAt 拿到
-- (table, nil) → 点牌时报 "attempt to compare table with number"。
local a = scene:anchorOf(scene.human)
check(type(a) == "table" and type(a[1]) == "number" and type(a[2]) == "number",
  "anchorOf 应返回 {x, y} 且元素都是数字（实得 " .. type(a) .. "）")

-- 注意 anchorOf 返回的是**表**，不能写 `local x, y = self:anchorOf(p)`
-- （那就是当初踩的坑：会拿到 (table, nil)）
local ok_pa, hit = pcall(function()
  local pa = scene:anchorOf(scene.human)
  return scene:panelAt(pa[1] + 5, pa[2] + 5)
end)
check(ok_pa, "panelAt 不应报错" .. (ok_pa and "" or ("：" .. tostring(hit))))
if ok_pa then
  check(hit == scene.human, "点击自己面板内应命中自己（实得 "
    .. tostring(hit and hit.name) .. "）")
end

-- 音频：headless（stub 的 love 没有 audio）下必须静默降级，绝不影响对局
local Audio = require "src.ui.audio"
local ok_audio, err_audio = pcall(function()
  local a = scene.audio or Audio.create(scene.skin)
  a:play("slash")
  a:play("不存在的键")
  a:play(nil)
  a:playCard("peach")
  a:setMuted(true)
  a:setVolume(0.5)
  a:setEnabled(false)
  assert(a:play("slash") == false, "禁用后应返回 false")
end)
check(ok_audio, "无音频环境下播放应静默降级"
  .. (ok_audio and "" or ("：" .. tostring(err_audio))))

print(string.format("\n===== UI: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("UI 测试失败", 0) end

end)

love = real_love
if not ok then error(fatal, 0) end
