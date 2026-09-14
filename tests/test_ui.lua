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

-- 拖拽放手：mousereleased 必须存在（main.lua 已接线），且空白处放手不应报错
check(type(scene.mousereleased) == "function", "应实现 mousereleased（拖拽出牌）")
local ok_mr, err_mr = pcall(function() scene:mousereleased(5, 5, 1) end)
check(ok_mr, "mousereleased() 在空白处应无异常" .. (ok_mr and "" or ("：" .. tostring(err_mr))))

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

-- 布局回归：面板必须整体落在画布内，且互不重叠。
-- 之前布局按皮肤里的 157 宽排版、绘制却画 210 宽，
-- 右侧面板（963+210=1173）超出 1130 被裁掉，顶上两块还互相压住。
do
  local W, H = love.graphics.getDimensions()
  local PW, PH = 210, 104
  local problems = {}
  for _, p in ipairs(scene.players) do
    local a = scene:anchorOf(p)
    if a[1] < 0 or a[2] < 0 or a[1] + PW > W or a[2] + PH > H then
      table.insert(problems, string.format("%s(%d,%d) 超出画布", p.name, a[1], a[2]))
    end
  end
  for i = 1, #scene.players do
    for j = i + 1, #scene.players do
      local a = scene:anchorOf(scene.players[i])
      local b = scene:anchorOf(scene.players[j])
      if math.abs(a[1] - b[1]) < PW and math.abs(a[2] - b[2]) < PH then
        table.insert(problems, scene.players[i].name .. " 与 "
          .. scene.players[j].name .. " 面板重叠")
      end
    end
  end
  check(#problems == 0, "5 人局面板应在画布内且互不重叠（"
    .. table.concat(problems, "；") .. "）")
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


-- 技能台词 / 阵亡台词：资源是拼音文件名，技能名是中文，靠 skill_keys 桥接
local skillKeys = require "src.ui.skill_keys"
local sk_ok, sk_bad = 0, {}
for zh in pairs(skillKeys) do
  if scene.skin:skillSound(zh) then sk_ok = sk_ok + 1 else table.insert(sk_bad, zh) end
end
check(#sk_bad == 0, "登记的 " .. sk_ok .. " 个技能台词都应能解析到音频文件（失败: "
  .. table.concat(sk_bad, ",") .. "）")
check(scene.skin:skillSound("奸雄") ~= nil, "【奸雄】应有台词文件")
check(scene.skin:skillSound("马术") == nil, "被动技【马术】原版就没有台词，应静默跳过")
check(scene.skin:sound("caocao") ~= nil, "阵亡台词应按武将拼音 key 解析（caocao）")


print("\n--- 技能视觉效果 ---")
do
  local Effects = require "src.ui.effects"
  local fx = Effects.create()

  -- 1) 面板闪光：加入后应存在，随时间衰减消失
  fx:flashPanel(10, 20, 200, 90)
  check(#fx.flashes == 1, "flashPanel 应记录一次闪光")
  fx:update(2)
  check(#fx.flashes == 0, "闪光应在时间到后消失")

  -- 2) 技能事件：即使台词播放失败（无音频/无台词），也要有横幅与闪光
  local sc = scene
  sc.effects = Effects.create()
  sc.audio = { playSkill = function() return false end, play = function() return false end }
  sc.room:emit("skill", { player = sc.human, skill = "马术" }) -- 被动技，无台词
  check(sc.effects.banner ~= nil,
    "无台词的技能发动也应显示横幅（实得 " .. tostring(sc.effects.banner) .. "）")
  check(#sc.effects.flashes == 1, "技能发动应在武将面板上闪一下")

  -- 3) 有台词的技能同样要有视觉
  sc.effects = Effects.create()
  sc.audio = { playSkill = function() return true end, play = function() return true end }
  sc.room:emit("skill", { player = sc.human, skill = "奸雄" })
  check(sc.effects.banner ~= nil, "有台词的技能发动应显示横幅")

  -- 4) 横幅文案应带上技能名
  local text = sc.effects.banner and sc.effects.banner.text or ""
  check(text:find("奸雄", 1, true) ~= nil,
    "横幅应包含技能名（实得「" .. text .. "」）")
end

print("\n--- 拖拽出牌 ---")
do
  local Card = require "src.core.card"
  local Cards = require "src.core.cards"

  -- 构造一个可控局面：人类手上一张【杀】，当前请求为 askForUseCard
  local function setupDrag()
    local sc = RoomScene.create(function() end)
    local slash = Card.create(9001, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
    table.insert(sc.human.hand, slash)
    sc.picked = nil
    sc.dragging = nil
    sc.msg = ""
    sc.room.pending = { type = "askForUseCard", player = sc.human }
    return sc, slash
  end

  -- 1) 按下卡牌应进入「已选中 + 拖拽中」
  local sc, slash = setupDrag()
  local req = sc.room.pending
  local idx = #sc.human.hand
  local cx, cy = sc:handCardRect(idx)
  sc:mousepressed(cx + 5, cy + 5, 1)
  check(sc.picked == slash, "按下卡牌应进入已选中状态")
  check(sc.dragging == slash, "按下卡牌应同时进入拖拽状态")

  -- 2) 拖到自己身上不合法（杀的目标是别人）
  local selfPanel = sc:anchorOf(sc.human)
  if selfPanel then
    check(sc:dropState(sc.human) ~= "ok", "【杀】不能拖到自己身上")
  end

  -- 3) 拖到距离内的敌人：松手应打出
  local victim = nil
  for _, q in ipairs(sc.players) do
    if q ~= sc.human and q.alive and sc:isValidTarget(q) then victim = q break end
  end
  if victim then
    local a = sc:anchorOf(victim)
    local before = #sc.human.hand
    sc:mousereleased(a[1] + 5, a[2] + 5, 1)
    check(#sc.human.hand < before, "拖到合法目标松手应打出该牌（手牌 "
      .. before .. " -> " .. #sc.human.hand .. "）")
    check(sc.dragging == nil, "打出后应清除拖拽状态")
  else
    print("SKIP  本局没有距离内的合法目标，跳过打出用例")
  end

  -- 4) 拖到距离外的目标：不应打出，且要给出原因
  local sc2, slash2 = setupDrag()
  sc2.picked, sc2.dragging = slash2, slash2 -- 等价于 mousepressed 后的状态
  local far = nil
  for _, q in ipairs(sc2.players) do
    if q ~= sc2.human and q.alive and not sc2:isValidTarget(q) then far = q break end
  end
  if far then
    local a = sc2:anchorOf(far)
    local before = #sc2.human.hand
    sc2:mousereleased(a[1] + 5, a[2] + 5, 1)
    check(#sc2.human.hand == before, "拖到非法目标松手不应打出该牌")
    check((sc2.msg or "") ~= "", "非法目标应给出提示（实得「" .. tostring(sc2.msg) .. "」）")
    local why = sc2:rejectReason(far)
    check(why ~= nil, "应能说明被拒绝的原因（实得 " .. tostring(why) .. "）")
  else
    print("SKIP  本局所有目标都合法，跳过距离不足用例")
  end

  -- 5) 距离提示文案应包含攻击范围
  local sc3, slash3 = setupDrag()
  sc3.picked, sc3.dragging = slash3, slash3
  local txt = sc3:dragStatusText()
  check(txt ~= nil and txt:find("攻击范围", 1, true) ~= nil,
    "拖拽提示应显示攻击范围（实得 " .. tostring(txt) .. "）")

  -- 6) 松手在空白处：保留已选中，不取消（两段式仍可用）
  local sc4, slash4 = setupDrag()
  sc4.picked, sc4.dragging = slash4, slash4
  sc4:mousereleased(5, 5, 1)
  check(sc4.picked == slash4, "松手在空白处应保留已选中状态")
end

print(string.format("\n===== UI: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("UI 测试失败", 0) end

end)

love = real_love
if not ok then error(fatal, 0) end
