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
    line = function() end,
    polygon = function() end,
    setLineWidth = function() end,
    draw = function() end,
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

-- 点击武将头像应打开技能说明；Esc 和弹层外点击都能关闭，且不触发退场确认。
do
  local target = nil
  for _, p in ipairs(scene.players) do
    if p.general and #(p.general.skills or {}) > 0 then target = p break end
  end
  check(target ~= nil, "测试局中应至少有一名带技能的武将")
  if target then
    local r = scene:avatarRect(target)
    check(scene:avatarAt(r.x + r.w / 2, r.y + r.h / 2) == target,
      "武将头像中心应命中对应角色")
    scene:mousepressed(r.x + r.w / 2, r.y + r.h / 2, 1)
    check(scene.skillPopup and scene.skillPopup.general_name == target.general.name,
      "点击武将头像应打开该武将的技能说明")
    check(scene.skillPopup and #scene.skillPopup.entries > 0
      and scene.skillPopup.entries[1].desc ~= "该技能暂无详细说明。",
      "技能弹层应包含技能名与有效说明")
    local okPopup = pcall(function() scene:draw() end)
    check(okPopup, "技能说明弹层绘制不应报错")
    scene:keypressed("escape")
    check(scene.skillPopup == nil and not scene.confirmExit,
      "技能弹层打开时 Esc 应只关闭弹层")
    scene:mousepressed(r.x + 2, r.y + 2, 1)
    scene:mousepressed(0, 0, 1)
    check(scene.skillPopup == nil, "点击技能弹层外区域应关闭弹层")
  end
end

-- 【制衡】装备多选：本人面板里的装备必须可命中、选中并随响应返回。
do
  local Card = require "src.core.card"
  local eq = Card.create(9901, "halberd", Card.Suit.Diamond, 12, Card.Type.Equip)
  local old_eq = scene.human.equips.weapon
  local old_pending, old_buttons = scene.room.pending, scene.buttons
  local old_queue, old_selected = scene.presentQueue, scene.selected
  scene.human.equips.weapon = eq
  scene.room.pending = {
    type = "askForDiscard", player = scene.human, n = 1,
    any = true, include_equips = true, cards = { eq },
  }
  scene.buttons, scene.presentQueue, scene.selected = {}, {}, {}
  local pa = scene:anchorOf(scene.human)
  local chip
  for _, c in ipairs(scene:panelChips(scene.human, pa[1], pa[2])) do
    if c.kind == "weapon" then chip = c end
  end
  check(chip ~= nil, "装备武器后面板应生成武器小牌")
  local got, slot = scene:equipCardAt(chip.x + 2, chip.y + 2)
  check(got == eq and slot == "weapon", "点击本人装备小牌应命中装备牌")
  scene:mousepressed(chip.x + 2, chip.y + 2, 1)
  local selected = scene:selectedCards()
  check(scene.selected[eq] and #selected == 1 and selected[1] == eq,
    "制衡应允许在装备框中选中装备牌")
  scene.human.equips.weapon = old_eq
  scene.room.pending, scene.buttons = old_pending, old_buttons
  scene.presentQueue, scene.selected = old_queue, old_selected
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


print("\n--- 演示节奏（防止语音重叠）---")
do
  local sc = RoomScene.create(function() end)

  -- 1) 事件应先入队，而不是立即播放
  sc.room:emit("skill", { player = sc.human, skill = "奸雄" })
  sc.room:emit("useCard", { card = nil, from = sc.human })
  check(#sc.presentQueue >= 1, "表现事件应先入队（实得 " .. #sc.presentQueue .. "）")
  check(sc:isPresenting(), "有未播事件时应处于演示中")

  -- 2) 一次 update 只播一条，不会一股脑全放出来
  local before = #sc.presentQueue
  sc:update(2)
  check(#sc.presentQueue == before - 1,
    "一次 update 只应播一条（" .. before .. " -> " .. #sc.presentQueue .. "）")

  -- 3) 演示期间不接受玩家操作，避免画面与状态错位
  sc.room:emit("skill", { player = sc.human, skill = "奸雄" })
  sc:mousepressed(200, 300, 1)
  check((sc.msg or "") == "对手行动中…",
    "演示中点击应被忽略（实得「" .. tostring(sc.msg) .. "」）")

  -- 4) 队列排空后恢复可操作
  for _ = 1, 20 do sc:update(2) end
  check(not sc:isPresenting(), "队列排空后应恢复可操作")

  -- 5) 不同事件的间隔：技能台词要留够时间，不能比出牌还短
  local PRESENT = { useCard = 0.42, skill = 0.62, damage = 0.34, death = 0.85 }
  check(PRESENT.skill > PRESENT.useCard, "技能间隔应长于出牌（台词更长）")
  check(PRESENT.death > PRESENT.skill, "阵亡间隔应最长")
end

print("\n--- 联机牌桌（UI 联调）---")
do
  -- 用内存通道把 Host 与联机界面接起来，验证「收到 req → 点牌 → 点人 → 应答」
  local Channel = require "src.net.channel"
  local Client = require "src.net.client"
  local Host = require "src.net.host"
  local NetScene = require "src.ui.scene_net"

  local host = Host.create { count = 5 }
  local srvCh, cliCh = Channel.pair()
  local seat = host:attach("我", srvCh)
  local cli = Client.create("我", cliCh)
  local sc = NetScene.create(function() end, cli, "我")
  check(sc ~= nil, "应能创建联机界面")
  check(seat == 1, "应占 1 号座")

  -- 服务端开局并推进到需要人类应答
  host:startGame(2024)
  local guard = 0
  while not host.waiting and guard < 500 do
    guard = guard + 1
    host:tick()
  end
  check(host.waiting ~= nil, "人类座位应收到请求")
  -- 模拟服务端下发 welcome（真实场景由 Server 发），界面据此认座位
  srvCh:send { type = "welcome", seat = seat, count = 5, token = "tok" }
  srvCh:send { type = "state", snapshot = host:snapshot() }
  sc:poll()
  check(sc.seat == seat, "界面应知道自己的座位（实得 " .. tostring(sc.seat) .. "）")
  check(sc.snap ~= nil, "界面应拿到服务端快照")
  check(sc.snap and sc.snap.players[1] and type(sc.snap.players[1].skills) == "table",
    "联机快照应下发公开的武将技能名")

  -- 联机面板点击武将信息区也应打开同一技能说明弹层。
  if sc.snap and sc.snap.players[1] and sc.snap.players[1].general then
    local ar = sc:avatarRect(1)
    sc:mousepressed(ar.x + 4, ar.y + 4, 1)
    check(sc.skillPopup and sc.skillPopup.general_name == sc.snap.players[1].general,
      "联机牌桌点击武将信息应打开技能说明")
    local popupDraw = pcall(function() sc:draw() end)
    check(popupDraw, "联机技能说明弹层绘制不应报错")
    sc:keypressed("escape")
    check(sc.skillPopup == nil, "联机技能说明弹层应可用 Esc 关闭")
  end

  -- 把服务端已产生的 req 送过去（真实场景走 socket）
  local pending = srvCh:recv()
  while pending do
    if pending.type == "req" then cliCh:send(pending) end
    pending = srvCh:recv()
  end
  sc:poll()

  -- 应答：结束出牌
  if sc.req then
    local reqId = sc.req.id
    sc:_respond(nil)
    check(sc.req == nil, "应答后应清空待处理请求")
    -- 服务端应能收到这条应答（前面可能还有 hello/ready，需逐条找）
    local got, seenTypes = nil, {}
    repeat
      got = srvCh:recv()
      if got then table.insert(seenTypes, got.type) end
    until got == nil or got.type == "resp"
    check(got ~= nil and got.type == "resp" and got.id == reqId,
      "服务端应收到应答（实得 " .. tostring(got and got.type)
      .. "，期间收到过: " .. table.concat(seenTypes, ",") .. "）")
  else
    print("SKIP  本轮未拿到请求，跳过应答用例")
  end

  -- 绘制不应报错
  local okDraw = pcall(function() sc:draw() end)
  check(okDraw, "联机界面 draw() 应无异常")
end

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
  sc.audio = { playSkill = function() return false end, play = function() return false end,
    voiceBusy = function() return false end }
  sc.room:emit("skill", { player = sc.human, skill = "马术" }) -- 被动技，无台词
  sc:update(2) -- 事件入队，需要 update 才会播（演示队列）
  check(sc.effects.banner ~= nil,
    "无台词的技能发动也应显示横幅（实得 " .. tostring(sc.effects.banner) .. "）")
  check(#sc.effects.flashes == 1, "技能发动应在武将面板上闪一下")

  -- 3) 有台词的技能同样要有视觉
  sc.effects = Effects.create()
  sc.audio = { playSkill = function() return true end, play = function() return true end,
    voiceBusy = function() return false end }
  sc.room:emit("skill", { player = sc.human, skill = "奸雄" })
  sc:update(2)
  check(sc.effects.banner ~= nil, "有台词的技能发动应显示横幅")

  -- 4) 横幅文案应带上技能名
  local text = sc.effects.banner and sc.effects.banner.text or ""
  check(text:find("奸雄", 1, true) ~= nil,
    "横幅应包含技能名（实得「" .. text .. "」）")
end

print("\n--- 拖拽出牌 ---")
do
  local Card = require "src.core.card"

  -- 构造一个可控局面：人类手上一张【杀】，当前请求为 askForUseCard
  --
  -- **不能直接覆盖 room.pending**：协程停在哪个 yield 上是有状态的。
  -- 开局时 pending 完全可能是 askForSkillInvoke（随机武将先弹技能征询），
  -- 此时把 pending 改写成 askForUseCard，后续 room:step 传入的
  -- {card, target} 会被协程当成「是否发动技能」来解读（非 true → 不发动），
  -- 【杀】根本进不了结算 —— 表现就是「拖过去什么也没发生」，测试随机红。
  -- 正确做法是**推进到真实的出牌请求**，而不是伪造一个。
  local function setupDrag()
    local sc = nil
    for _ = 1, 10 do
      -- 固定 seed：武将、发牌、身份、第一个 pending 的类型全部确定，
      -- 用例才是可复现的（否则「有没有距离内的目标」每次都不一样）
      sc = RoomScene.create(function() end, "identity", 5, "off", { seed = 20260914 })
      local guard = 0
      while not sc.room.game_over and guard < 200 do
        guard = guard + 1
        local req = sc.room.pending
        if not req then break end
        if req.type == "askForUseCard" and req.player == sc.human then break end
        sc:_step(nil) -- 其余请求一律「不发动 / 跳过」，把引擎推到出牌阶段
      end
      local req = sc.room.pending
      -- 还得有距离内的合法目标：没有的话 mousepressed 会以「没有合法目标」
      -- 直接拒绝选中（picked 保持 nil），用例照样无从验证
      if req and req.type == "askForUseCard" and req.player == sc.human then
        local slash = Card.create(9001, "slash", Card.Suit.Spade, 5, Card.Type.Basic)
        table.insert(sc.human.hand, slash)
        sc.picked = slash
        local reachable = false
        for _, q in ipairs(sc.players) do
          if q ~= sc.human and q.alive and sc:isValidTarget(q) then
            reachable = true break
          end
        end
        sc.picked = nil
        if reachable then
          sc.dragging = nil
          sc.msg = ""
          -- 推进对局会触发技能/出牌的演示动画（presentQueue）。
          -- 演示没播完时 mousepressed 直接 return（isPresenting 保护），
          -- picked 永远是 nil。这里直接清空队列：update(dt) 每帧只消费一项，
          -- 引擎又会补新的，等不完。
          sc.presentQueue = {}
          return sc, slash
        end
      end
      sc = nil
    end
    return nil, nil
  end

  -- 1) 按下卡牌应进入「已选中 + 拖拽中」
  local sc, slash = setupDrag()
  if sc then -- 拿不到出牌阶段就整体跳过（见 setupDrag 注释）
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
    local after = #sc.human.hand
    check(after < before, "拖到合法目标松手应打出该牌（手牌 "
      .. before .. " -> " .. after .. "）"
      .. (after < before and "" or
        ("  [诊断] 目标=" .. tostring(victim.name)
          .. " 点中=" .. tostring(sc:panelAt(a[1] + 5, a[2] + 5) == victim)
          .. " 拒绝原因=" .. tostring(sc:rejectReason(victim))
          .. " msg=" .. tostring(sc.msg)
          .. " pending=" .. tostring(sc.room.pending and sc.room.pending.type)
          .. " 演示中=" .. tostring(sc:isPresenting()))))
    check(sc.dragging == nil, "打出后应清除拖拽状态")
  else
    print("SKIP  本局没有距离内的合法目标，跳过打出用例")
  end

  -- 4) 拖到距离外的目标：不应打出，且要给出原因
  local sc2, slash2 = setupDrag()
  if sc2 then
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
  end

  -- 5) 距离提示文案应包含攻击范围
  local sc3, slash3 = setupDrag()
  if sc3 then
    sc3.picked, sc3.dragging = slash3, slash3
    local txt = sc3:dragStatusText()
    check(txt ~= nil and txt:find("攻击范围", 1, true) ~= nil,
      "拖拽提示应显示攻击范围（实得 " .. tostring(txt) .. "）")
  end

  -- 6) 松手在空白处：保留已选中，不取消（两段式仍可用）
  local sc4, slash4 = setupDrag()
  if sc4 then
    sc4.picked, sc4.dragging = slash4, slash4
    sc4:mousereleased(5, 5, 1)
    check(sc4.picked == slash4, "松手在空白处应保留已选中状态")
  end
  else
    print("SKIP  没能推进到出牌阶段，跳过拖拽用例")
  end
end

print()
print("--- AI 托管接入 ---")
do
  package.loaded["src.ui.scene_room"] = nil
  local RoomSceneAI = require "src.ui.scene_room"
  -- 未设置 SGS_AI_URL/SGS_AI_KEY 时不该崩：Agent 会自动回落规则 BOT
  local sc = RoomSceneAI.create(function() end, "identity", 5, "others")
  check(sc.agent ~= nil, "开启 AI 托管后应创建 Agent")

  local ai_seats = 0
  for _, p in ipairs(sc.players) do
    if p:controlMode() == "ai" then ai_seats = ai_seats + 1 end
  end
  check(ai_seats == 4, "非人类座位应全部交给 AI（实得 " .. ai_seats .. " 个）")
  check(sc.players[1]:controlMode() == "human", "1 号位默认应由玩家自己操作")

  local ok_u, err_u = pcall(function()
    for _ = 1, 300 do sc:update(0.016) end
  end)
  check(ok_u, "AI 托管下连续 update 300 帧应无异常" .. (ok_u and "" or ("：" .. tostring(err_u))))
  check(sc.room.turn_count > 0, "AI 托管下对局应有推进（第 " .. sc.room.turn_count .. " 轮）")

  local ok_d, err_d = pcall(function() sc:draw() end)
  check(ok_d, "AI 托管下 draw() 应无异常" .. (ok_d and "" or ("：" .. tostring(err_d))))

  -- 数字键切换任意座位的控制权
  local ok_k, err_k = pcall(function() sc:keypressed("1") end)
  check(ok_k and sc.players[1]:controlMode() == "ai",
    "按 1 应把 1 号位交给 AI" .. (ok_k and "" or ("：" .. tostring(err_k))))
  sc:keypressed("1")
  check(sc.players[1]:controlMode() == "human", "再按 1 应变回玩家操作")
  sc:keypressed("9")
  check(#sc.players == 5, "按不存在的座位号不应有影响")
end

print("\n--- 退出对局 ---")
do
  local sc = RoomScene.create(function() end)
  local hasExit = false
  sc:_refreshButtons()
  for _, b in ipairs(sc.buttons) do
    if b.text == "退出对局" then hasExit = true end
  end
  check(hasExit, "应常驻「退出对局」按钮")

  -- 二次确认：第一次只进确认态，不退出
  local exited = false
  sc.on_exit = function() exited = true end
  sc:keypressed("escape")
  check(sc.confirmExit == true, "按 Esc 应进入确认态")
  check(not exited, "确认前不应真的退出")
  -- 再按一次 Esc 是取消（设计上 Esc 第二次=取消，确认走按钮）
  sc:keypressed("escape")
  check(sc.confirmExit == false, "确认态再按 Esc 应取消")
  -- 按钮确认退出
  sc:keypressed("escape")
  for _, b in ipairs(sc.buttons) do
    if b.text == "确认退出？" then b.cb() end
  end
  check(exited, "点【确认退出？】应真的退出")

  -- 数字键托管切换不能被 Esc 改动覆盖掉（整个文件只有一个 keypressed）
  local sc2 = RoomScene.create(function() end)
  sc2:keypressed("1")
  check(sc2.players[1]:controlMode() == "ai",
    "数字键切换 AI 托管仍应可用（实得 " .. sc2.players[1]:controlMode() .. "）")
end

print("\n--- 开局选将（opt-in：draft 流程）---")

do
  -- 未启用选将（默认）：老流程直接开局，不该出现选将阶段
  local sc = RoomScene.create(function() end, "identity", 5, "off", { seed = 42 })
  check(sc.draft == nil, "未启用选将时应直接开局")
  check(sc.driver ~= nil, "未启用选将时驱动器应就绪")

  -- 启用选将：房间未开局、候选数量与身份匹配；选定后正常开局
  local sd = RoomScene.create(function() end, "identity", 5, "off",
    { seed = 42, draft = true })
  check(sd.draft ~= nil, "启用选将时应停留在选将阶段")
  check(sd.driver == nil, "选将未完成前不应创建驱动器")
  local want = (sd.human.role == "lord") and 5 or 3
  check(sd.draft.candidates and #sd.draft.candidates == want,
    string.format("候选应为主公 5 张 / 其余 3 张（实得 %d）",
      sd.draft.candidates and #sd.draft.candidates or -1))

  -- 每张候选都应能命中内置头像资源；drawDraft 应实际绘制每张头像。
  local all_avatar_assets = true
  for _, g in ipairs(sd.draft.candidates or {}) do
    if not sd.skin:generalImage(g.key) then all_avatar_assets = false break end
  end
  check(all_avatar_assets, "选将候选应都有可加载的武将头像资源")
  local fake = {
    getWidth = function() return 134 end,
    getHeight = function() return 134 end,
  }
  local old_general_image, old_draw = sd.generalImage, love.graphics.draw
  local avatar_draws = 0
  sd.generalImage = function() return fake end
  love.graphics.draw = function(img)
    if img == fake then avatar_draws = avatar_draws + 1 end
  end
  local ok_draft, err_draft = pcall(function() sd:drawDraft() end)
  sd.generalImage, love.graphics.draw = old_general_image, old_draw
  check(ok_draft, "带头像的选将画面绘制不应报错"
    .. (ok_draft and "" or ("：" .. tostring(err_draft))))
  check(avatar_draws == want,
    string.format("选将画面应绘制每张候选头像（%d/%d）", avatar_draws, want))

  -- 选将阶段 update 不应崩（驱动器尚未就绪）
  sd:update(0.016)
  -- 同种子下 BOT 座位已「秒选」，名字与新武将一致
  local named = true
  for i, p in ipairs(sd.players) do
    if i > 1 and p.name ~= "BOT·" .. p.general.name then named = false end
  end
  check(named, "BOT 座位应已从各自候选池选定")
  -- 选定第一张候选 → 进入对局
  local pick = sd.draft.candidates[1]
  sd:pickGeneral(pick)
  check(sd.draft == nil, "选将完成后应进入对局")
  check(sd.driver ~= nil, "选将完成后驱动器应就绪")
  check(sd.human.general == pick, "应落到玩家自己选定的武将")
  check(sd.human.max_hp == pick.max_hp + ((sd.human.role == "lord") and 1 or 0),
    "主公体力上限 +1 应重算")
  -- 座位 1（真人）先手：beginPlay 内 advance 停在第一个待响应的请求。
  -- 选到的武将若有出牌阶段前的发动询问（如颜良文丑【双雄】、甄姬【洛神】），
  -- advance 会先停在那里——逐个婉拒，直到真正的出牌询问再核对摸牌结果。
  local guard = 0
  while sd.room.pending and sd.room.pending.type ~= "askForUseCard"
    and guard < 8 do
    guard = guard + 1
    local req = sd.room.pending
    if req.type == "askForSkillInvoke" or req.type == "askForGuanxing" then
      sd.room:step(false) -- 不发动 / 观星保持原序
    else
      sd.room:step(nil)   -- 其余询问给空响应（引擎有默认兜底）
    end
  end
  check(sd.room.pending and sd.room.pending.type == "askForUseCard",
    "婉拒后应推进到真人的出牌询问（实得 "
      .. tostring(sd.room.pending and sd.room.pending.type) .. "）")
  check(#sd.human.hand == 6,
    "真人先手：起始 4 + 首回合摸 2（实得 " .. #sd.human.hand .. "）")
  local dealt = true
  for i, p in ipairs(sd.players) do
    if i > 1 and #p.hand ~= 4 then dealt = false end
  end
  check(dealt, "其余座位应为起始 4 张手牌")
end

print("\n--- 表现层：技能指向 / 出牌飞牌 / 响应与装备反馈 ---")

do
  local scene = RoomScene.create(function() end, "identity", 5, "off", { seed = 42 })
  local fx = scene.effects
  check(fx ~= nil, "场景应创建特效层")
  local p1, p2 = scene.players[1], scene.players[2]
  local card = p1.hand[1]

  -- 出牌对准目标：入队 → 播放 → 应产生指向箭头与飞牌
  scene.room:emit("useCard", { card = card, from = p1, to = { p2 } })
  check(#scene.presentQueue == 1, "useCard 事件应入演示队列")
  scene:playPresent(table.remove(scene.presentQueue, 1))
  check(#fx.flies == 1 and #fx.arrows == 1,
    "对目标出牌应产生 1 条飞牌与 1 条指向箭头（飞 " .. #fx.flies
      .. "，箭 " .. #fx.arrows .. "）")

  -- 无目标牌（如无中生有）：只飞牌、不画箭头，落点是屏幕中央
  scene.room:emit("useCard", { card = card, from = p1, to = {} })
  scene:playPresent(table.remove(scene.presentQueue, 1))
  check(#fx.flies == 2 and #fx.arrows == 1,
    "无目标出牌只应飞牌不画箭头（飞 " .. #fx.flies .. "，箭 " .. #fx.arrows .. "）")

  -- BOT 打出响应牌（杀被闪）：飞牌 + 面板高亮
  scene.room:emit("respond", { player = p2, card = card, reason = "dodge" })
  scene:playPresent(table.remove(scene.presentQueue, 1))
  check(#fx.flies == 3, "打出响应牌应有飞牌动画（实得 " .. #fx.flies .. " 条）")

  -- 装备上阵：飞牌挂到自己面板
  scene.room:emit("equip", { player = p2, card = card, slot = "weapon" })
  scene:playPresent(table.remove(scene.presentQueue, 1))
  check(#fx.flies == 4, "装备上阵应有飞牌动画（实得 " .. #fx.flies .. " 条）")

  -- 技能指向：施法者 → 目标
  scene.room:emit("skillTarget", { player = p1, target = p2, skill = "试炼" })
  scene:playPresent(table.remove(scene.presentQueue, 1))
  check(#fx.arrows == 2, "技能指定目标应画指向箭头（实得 " .. #fx.arrows .. " 条）")

  -- 伤害：来源 → 受害者的红色指向
  scene.room:emit("damage", { to = p2, from = p1, n = 1 })
  scene:playPresent(table.remove(scene.presentQueue, 1))
  check(#fx.arrows == 3, "伤害命中应画来源指向（实得 " .. #fx.arrows .. " 条）")

  -- 动画推进与绘制不应报错；到期后清理干净
  fx:arrow(10, 10, 200, 200)
  fx:update(0.1)
  local ok_draw, err_draw = pcall(function() fx:draw(1130, 650, stub_font, stub_font) end)
  check(ok_draw, "特效绘制（含箭头/飞牌）不应报错"
    .. (ok_draw and "" or ("：" .. tostring(err_draw))))
  fx:update(10)
  check(#fx.arrows == 0 and #fx.flies == 0, "动画到期后应清理干净")
end

print("\n--- 暂停 ---")

do
  local sc = RoomScene.create(function() end, "identity", 5, "off", { seed = 42 })
  check(sc.paused == false, "开局默认不暂停")

  -- 按钮列应有【暂停】，点击进入暂停
  sc:_refreshButtons()
  local pause_btn
  for _, b in ipairs(sc.buttons) do
    if b.text == "暂停" then pause_btn = b end
  end
  check(pause_btn ~= nil, "按钮列应有【暂停】")
  if pause_btn then pause_btn.cb() end
  check(sc.paused == true, "点【暂停】应进入暂停")

  -- 暂停时 update 不推进：演示队列倒计时冻结（队列长度与计时不变）
  sc.room:emit("skill", { player = sc.players[2], skill = "马术" })
  sc.presentTimer = 0.5
  local q_len = #sc.presentQueue
  sc:update(1.0)
  check(#sc.presentQueue == q_len and sc.presentTimer == 0.5,
    "暂停时演示队列不应推进")

  -- 暂停中点击只认【继续】：点手牌中心不应选中牌
  local paused_pick = sc.picked
  local cx, cy = sc:handCardRect(1)
  sc:mousepressed(cx + 31, cy + 43, 1)
  check(sc.picked == paused_pick, "暂停中点手牌应被遮罩拦截")

  -- 点【继续】恢复；P 键也能切换
  local r = sc:pauseOverlayLayout().resume
  sc:mousepressed(r.x + 5, r.y + 5, 1)
  check(sc.paused == false, "点【继续】应恢复对局")
  sc:keypressed("p")
  check(sc.paused == true, "按 P 应暂停")
  sc:keypressed("p")
  check(sc.paused == false, "再按 P 应恢复")

  -- 暂停遮罩绘制不报错
  sc.paused = true
  local ok_draw, err = pcall(function() sc:draw() end)
  check(ok_draw, "暂停遮罩绘制不应报错" .. (ok_draw and "" or ("：" .. tostring(err))))
  sc.paused = false

  -- 对局结束后不再显示暂停按钮（只有返回菜单）
  sc.room.game_over = true
  sc:_refreshButtons()
  local still = false
  for _, b in ipairs(sc.buttons) do
    if b.text == "暂停" then still = true end
  end
  check(not still, "对局结束不应再有【暂停】按钮")
end

print("\n--- 座位按顺时针排列 ---")

do
  -- 引擎回合按座位号 1→N 推进；布局必须让座位号在视觉上构成一圈
  -- 顺时针（你 → 左 → 上 → 右），否则出牌顺序看起来在桌上乱跳
  local Layout = require "src.ui.layout"
  local function zones(n)
    local L = Layout.create(nil, n, 210, 104)
    local out = {}
    for seat = 1, n do
      local x, y = L.anchors[seat][1], L.anchors[seat][2]
      local zone
      if seat == 1 then zone = 0 -- 自己（底部）
      elseif y < 160 then zone = 2 -- 顶排
      elseif x < 400 then zone = 1 -- 左列
      else zone = 3 end -- 右列
      out[#out + 1] = { zone = zone, x = x, y = y }
    end
    return out
  end

  for _, n in ipairs({ 2, 4, 5, 8 }) do
    local z = zones(n)
    local mono = true
    for i = 2, #z - 1 do
      if z[i + 1].zone < z[i].zone then mono = false end
    end
    check(mono, string.format("%d 人局座位应沿顺时针单调排列（左→上→右）", n))
    -- 同列内部方向：左列自下而上（y 随座位递减）、顶排从左到右（x 递增）
    for i = 3, #z - 1 do
      if z[i].zone == 1 and z[i + 1].zone == 1 and z[i + 1].y > z[i].y then
        check(false, string.format("%d 人局左列应自下而上", n))
      end
      if z[i].zone == 2 and z[i + 1].zone == 2 and z[i + 1].x < z[i].x then
        check(false, string.format("%d 人局顶排应从左到右", n))
      end
    end
  end

  local z5 = zones(5)
  check(z5[2].zone == 1 and z5[3].zone == 2 and z5[4].zone == 2 and z5[5].zone == 3,
    "5 人局应为 你→左→上左→上右→右（实得区域 "
      .. table.concat({ z5[2].zone, z5[3].zone, z5[4].zone, z5[5].zone }, ",") .. "）")
end

print("\n--- 主菜单 ---")

do
  local Menu = require "src.ui.scene_menu"
  local picked = {}
  local m = Menu.create(function(mode, size, ai, draft)
    picked[#picked + 1] = { mode = mode, size = size, ai = ai, draft = draft }
  end, function() picked[#picked + 1] = "net" end)

  local ok_draw, err = pcall(function() m:draw() end)
  check(ok_draw, "主菜单绘制不应报错" .. (ok_draw and "" or ("：" .. tostring(err))))
  local ok_upd, err_upd = pcall(function() m:update(0.016) end)
  check(ok_upd, "主菜单 update（悬停轮询）不应报错"
    .. (ok_upd and "" or ("：" .. tostring(err_upd))))

  -- AI 托管三档循环：关 → 其他座位 → 全部 → 关
  local ab = m.ai_button
  m:mousepressed(ab.x + 1, ab.y + 1, 1)
  check(m.ai_button.text == "AI 托管：其他座位", "AI 托管点击应切到「其他座位」")
  m:mousepressed(ab.x + 1, ab.y + 1, 1)
  check(m.ai_button.text == "AI 托管：全部", "AI 托管再点应切到「全部」")
  m:mousepressed(ab.x + 1, ab.y + 1, 1)
  check(m.ai_button.text == "AI 托管：关", "AI 托管三轮应切回「关」")

  -- 开局选将开关
  local db = m.draft_button
  m:mousepressed(db.x + 1, db.y + 1, 1)
  check(m.draft_button.text == "开局选将：关", "开局选将点击应切到「关」")
  m:mousepressed(db.x + 1, db.y + 1, 1)
  check(m.draft_button.text == "开局选将：开", "再点应切回「开」")

  -- 点身份局（5 人）：应以 identity/5/当前 AI 档/选将开 回调
  local b5, bnet
  for _, b in ipairs(m.buttons) do
    if b.size == 5 then b5 = b elseif b.net then bnet = b end
  end
  m:mousepressed(b5.x + 1, b5.y + 1, 1)
  check(#picked == 1 and picked[1].mode == "identity" and picked[1].size == 5
      and picked[1].ai == "off" and picked[1].draft == true,
    "点身份局（5 人）应回调 identity/5/off/选将开（实得 " .. #picked .. " 个回调）")
  m:mousepressed(bnet.x + 1, bnet.y + 1, 1)
  check(picked[2] == "net", "联机按钮应触发 on_net")

  -- 布局自适应：换窗口尺寸后矩形应整体居中
  m:relayout(1600, 900)
  local total = m.buttons[3].x + m.buttons[3].w - m.buttons[1].x
  check(math.abs((m.buttons[1].x + total / 2) - 800) < 1,
    "身份局一排应在新窗口宽度下居中（中心偏差 "
      .. tostring(math.abs((m.buttons[1].x + total / 2) - 800)) .. "px）")
end

print("\n--- 牌桌：装备/判定区小牌、卡牌说明弹层、语音串行 ---")

do
  local Card = require "src.core.card"
  local SD = require "src.ui.skill_desc"
  local scene = RoomScene.create(function() end, "identity", 5, "off", { seed = 42 })
  local p2 = scene.players[2]

  -- 挂上防御马与乐不思蜀，面板应生成对应小牌（马带距离标注）
  local horse = Card.create(31, "defensive_horse", Card.Suit.Spade, 5, Card.Type.Equip)
  p2.equips.defensive_horse = horse
  local indulgence = Card.create(32, "indulgence", Card.Suit.Spade, 6, Card.Type.Trick)
  p2:addJudge(indulgence)
  local a = scene:anchorOf(p2)
  local chips = scene:panelChips(p2, a[1], a[2])
  check(#chips == 2, "装备 + 判定应生成 2 枚小牌（实得 " .. #chips .. "）")
  check(chips[1].text == "防御马+1",
    "防御马小牌应带 +1 距离标注（实得 " .. tostring(chips[1] and chips[1].text) .. "）")
  check(chips[2].text == "乐不思蜀" and chips[2].kind == "judge",
    "判定区小牌应显示牌名（实得 " .. tostring(chips[2] and chips[2].text) .. "）")

  -- 点小牌 → 弹出卡牌说明；点关闭 → 弹层消失
  scene:mousepressed(chips[1].x + 2, chips[1].y + 2, 1)
  check(scene.skillPopup ~= nil
      and scene.skillPopup.entries[1].name == "防御马"
      and scene.skillPopup.subtitle == "卡牌说明",
    "点装备小牌应弹出卡牌说明（实得 "
      .. tostring(scene.skillPopup and scene.skillPopup.entries[1].name) .. "）")
  local box = SD.layout(scene.skillPopup)
  scene:mousepressed(box.close.x + 2, box.close.y + 2, 1)
  check(scene.skillPopup == nil, "点关闭应关掉说明弹层")
  scene:mousepressed(chips[2].x + 2, chips[2].y + 2, 1)
  check(scene.skillPopup ~= nil and scene.skillPopup.entries[1].name == "乐不思蜀",
    "点判定小牌应弹出乐不思蜀说明")

  -- 语音串行：上一条台词没播完时，演示队列不推进
  scene.skillPopup = nil
  local busy = true
  scene.audio = setmetatable({}, { __index = function()
    return function() return busy end
  end })
  scene.room:emit("skill", { player = scene.players[1], skill = "试炼" })
  check(#scene.presentQueue == 1, "skill 事件应入演示队列")
  scene:update(1.0)
  check(#scene.presentQueue == 1, "台词未播完时队列不应推进（剩 " .. #scene.presentQueue .. "）")
  busy = false
  scene:update(1.0)
  check(#scene.presentQueue == 0, "台词播完后队列应继续推进")
end

-- Audio 模块：台词独占记录与 voiceBusy 判定（headless 恒为 false）
do
  local Audio = require "src.ui.audio"
  local audio = Audio.create()
  check(audio:voiceBusy() == false, "headless 下 voiceBusy 应为 false")
  check(audio:playSkill("奸雄") == false, "headless 下 playSkill 应静默返回 false")
  check(audio:playVoice("caocao") == false, "headless 下 playVoice 应静默返回 false")
end

print("\n--- 战斗日志截断不得拆坏 UTF-8 ---")

do
  -- 旧实现的续字节区间写反（[\128-\127] 空集）：中文被拆成孤立首字节，
  -- 超宽日志一截断，print 直接抛 Invalid UTF-8（实测崩过两次）
  local sc = RoomScene.create(function() end, "identity", 5, "off", { seed = 42 })
  local real_font = sc.font_sm
  sc.font_sm = setmetatable({ getWidth = function(_, t) return #t * 10 end },
    { __index = function() return function() end end })
  local function validUTF8(s)
    local i = 1
    while i <= #s do
      local b = string.byte(s, i)
      if b < 128 then i = i + 1
      elseif b >= 192 then
        local n = (b >= 240) and 4 or (b >= 224) and 3 or 2
        if i + n - 1 > #s then return false end
        for j = i + 1, i + n - 1 do
          local c = string.byte(s, j)
          if not c or c < 128 or c >= 192 then return false end
        end
        i = i + n
      else return false end
    end
    return true
  end
  local measure = function(t)
    if not (sc.font_sm and sc.font_sm.getWidth) then return nil end
    local ok2, w = pcall(sc.font_sm.getWidth, sc.font_sm, t)
    if not ok2 or type(w) ~= "number" then return nil end
    return w
  end

  local long = string.rep("张飞对曹操使用过河拆桥", 10) -- 纯中文超宽行
  local fitted = sc:fitLogLine(long, 300, measure)
  check(validUTF8(fitted), "超宽中文日志截断后应保持合法 UTF-8")
  check(#fitted < #long and fitted:sub(-3) == "…", "截断应收窄并以省略号结尾")
  local zh_char = fitted:match("[\228-\233][\128-\191][\128-\191]")
  check(zh_char ~= nil, "截断结果里应存在完整的中文字符（而非孤立首字节）")
  local short = sc:fitLogLine("短日志", 300, measure)
  check(short == "短日志", "未超宽应原样返回")
  local mixed = sc:fitLogLine(string.rep("BOT·曹操 uses 杀 slash!! ", 6), 300, measure)
  check(validUTF8(mixed), "中英混合截断也应保持合法")
  sc.font_sm = real_font

  -- draw 冒烟：塞一条超宽中文日志走完整绘制路径
  table.insert(sc.room.loglines, string.rep("超宽日志行内容测试", 12))
  local ok_draw, err_draw = pcall(function() sc:draw() end)
  check(ok_draw, "含超宽日志的 draw 不应报错"
    .. (ok_draw and "" or ("：" .. tostring(err_draw))))
end

print("\n--- AI 思考开关与推测展示 ---")

do -- 文本截断必须按 UTF-8 完整字符：字节级截断会让 print 抛 Invalid UTF-8
  local TextFit = require "src.ui.text_fit"
  -- 校验整个字符串是合法 UTF-8（无孤立续字节、无截断的多字节序列）
  local function validUTF8(s)
    local i = 1
    while i <= #s do
      local b = string.byte(s, i)
      if b < 128 then i = i + 1
      elseif b >= 192 then
        local n = (b >= 240) and 4 or (b >= 224) and 3 or 2
        if i + n - 1 > #s then return false end
        for j = i + 1, i + n - 1 do
          local c = string.byte(s, j)
          if not c or c < 128 or c >= 192 then return false end
        end
        i = i + n
      else return false end -- 孤立续字节
    end
    return true
  end

  local long = "张飞判断曹操是反贼因为他对主公使用了杀" -- 20 个汉字
  for _, n in ipairs({ 1, 2, 4, 5, 7, 10, 58, 59, 60, 61 }) do
    local t = TextFit.truncate(long, n)
    check(validUTF8(t), string.format("truncate(%d) 应保持合法 UTF-8（%q）", n, t))
  end
  check(TextFit.truncate(long, 100) == long, "不超长应原样返回")
  check(TextFit.truncate("abc", 2) == "a…", "ASCII 截断同样按字符")

  local f = TextFit.fit(long, 91) -- 91px ≈ 7 个汉字宽
  check(validUTF8(f) and TextFit.width(f) <= 91,
    "fit 应同时满足合法性与宽度（宽 " .. TextFit.width(f) .. "px）")
end

do
  local Menu = require "src.ui.scene_menu"
  local picked = {}
  local m = Menu.create(function(mode, size, ai, draft, think)
    picked[#picked + 1] = { mode = mode, think = think }
  end, function() end)

  -- 三档循环：关 → 低 → 高 → 关（环境变量未设时初值为关）
  local tb = m.think_button
  check(tb.text == "AI 思考：关", "环境变量未设时初值应为关（实得 " .. tb.text .. "）")
  m:mousepressed(tb.x + 1, tb.y + 1, 1)
  check(tb.text == "AI 思考：低", "点击应切到低（实得 " .. tb.text .. "）")
  m:mousepressed(tb.x + 1, tb.y + 1, 1)
  check(tb.text == "AI 思考：高", "再点应切到高（实得 " .. tb.text .. "）")
  m:mousepressed(tb.x + 1, tb.y + 1, 1)
  check(tb.text == "AI 思考：关", "三轮应切回关")

  -- 点身份局：第 5 参应把当前思考档传给 on_start
  m:mousepressed(tb.x + 1, tb.y + 1, 1) -- 切到低
  local b5
  for _, b in ipairs(m.buttons) do
    if b.size == 5 then b5 = b end
  end
  m:mousepressed(b5.x + 1, b5.y + 1, 1)
  check(picked[1] and picked[1].mode == "identity" and picked[1].think == "low",
    "on_start 第 5 参应透传思考档（实得 " .. tostring(picked[1] and picked[1].think) .. "）")
end

do
  -- 牌桌：ai_reasoning 落进场景；feed 推送与「AI 推测」弹层开合
  local sc = RoomScene.create(function() end, "identity", 5, "others",
    { seed = 42, ai_reasoning = "low" })
  check(sc.ai_reasoning == "low", "opts.ai_reasoning 应落进场景")
  check(sc.agent ~= nil, "AI 模式下应创建 Agent")

  sc:pushAIFeed("belief", "张飞 判 曹操：未知→反贼（他杀主公）", 3)
  sc:pushAIFeed("think", "张飞 思考：P2 对主公出杀")
  check(#sc.aiFeed == 2, "pushAIFeed 应累积（实得 " .. #sc.aiFeed .. " 条）")

  -- 按钮列应有「AI 推测」入口，点开弹层、内容可生成、Esc/外点关闭
  sc:_refreshButtons()
  local ai_btn
  for _, b in ipairs(sc.buttons) do
    if b.text == "AI 推测" then ai_btn = b end
  end
  check(ai_btn ~= nil, "AI 模式下按钮列应有【AI 推测】")
  if ai_btn then ai_btn.cb() end
  check(sc.aiPopup == true, "点【AI 推测】应打开弹层")
  local lines = sc:aiPopupLines()
  check(type(lines) == "table" and #lines > 0, "弹层内容行应可生成")
  local joined = table.concat(lines, "\n")
  check(joined:find("未知→反贼", 1, true) ~= nil, "弹层时间线应包含判断变化")
  check(joined:find("张飞 思考", 1, true) ~= nil, "弹层时间线应包含思维链摘要")
  local ok_draw, err = pcall(function() sc:draw() end)
  check(ok_draw, "弹层开着时 draw 不应报错" .. (ok_draw and "" or ("：" .. tostring(err))))
  sc:keypressed("escape")
  check(sc.aiPopup == nil, "Esc 应关闭弹层")

  -- 滚动：内容超出弹层高度时，滚轮/方向键翻看，且有边界钳制。
  -- 弹层会先自适应长高（时间线封顶 18 行），要 8 人局那种多座位
  -- 记忆 + notes 才会超出屏高——测试里注入假记忆撑出长内容
  for seat = 2, 9 do
    sc.agent.memories[seat] = require("src.core.ai.memory").create({ seat = seat })
    sc.agent.memories[seat].beliefs = { ["P1"] = "主公", ["P3"] = "反贼" }
    sc.agent.memories[seat].notes = "座位" .. seat .. "的长期观察记录"
  end
  for i = 1, 40 do sc:pushAIFeed("belief", "第" .. i .. "条判断变化记录") end
  sc.aiPopup = true
  sc.aiPopupScroll = 0
  local box = sc:aiPopupLayout()
  local max_fit = math.max(1, math.floor((box.h - 96) / 17))
  local max_scroll = math.max(0, #sc:aiPopupLines() - max_fit)
  check(max_scroll > 0, "多座位长内容应超出弹层高度（max_scroll="
    .. max_scroll .. "，若为 0 则本组滚动断言空转）")
  if max_scroll > 0 then
    sc:wheelmoved(0, -1)
    check(sc.aiPopupScroll == 3, "滚轮下滚一格应前进 3 行（实得 "
      .. tostring(sc.aiPopupScroll) .. "）")
    sc:wheelmoved(0, -100)
    check(sc.aiPopupScroll == max_scroll, "滚到底应钳制在最大行（实得 "
      .. tostring(sc.aiPopupScroll) .. "/" .. max_scroll .. "）")
    sc:wheelmoved(0, 1)
    check(sc.aiPopupScroll == max_scroll - 3, "上滚一格应回退 3 行（实得 "
      .. tostring(sc.aiPopupScroll) .. "）")
    sc:keypressed("home")
    check(sc.aiPopupScroll == 0, "Home 应回到顶部")
    sc:keypressed("end")
    check(sc.aiPopupScroll == max_scroll, "End 应跳到底部")
    sc:keypressed("down")
    check(sc.aiPopupScroll == max_scroll, "已到底再按 ↓ 不应越界")
    sc:keypressed("up")
    check(sc.aiPopupScroll == max_scroll - 1, "↑ 应回退一行")
    local ok_scroll_draw, err_sd = pcall(function() sc:draw() end)
    check(ok_scroll_draw, "滚动中途绘制（含滚动条）不应报错"
      .. (ok_scroll_draw and "" or ("：" .. tostring(err_sd))))
  end
  sc:keypressed("escape")
  check(sc.aiPopup == nil, "滚动后 Esc 仍应关闭弹层")
  sc.aiPopup = true
  local box = sc:aiPopupLayout()
  check(sc:aiPopupShouldClose(box.close.x + 2, box.close.y + 2), "点关闭钮应判定关闭")
  check(not sc:aiPopupShouldClose(box.x + 50, box.y + 60), "弹层内部不应判定关闭")

  -- 小面板只在 belief 类显示最近变化；draw 已含（上面 pcall 覆盖弹层+面板路径）
  sc.aiPopup = nil
  local ok2, err2 = pcall(function() sc:draw() end)
  check(ok2, "AI 模式下 draw（含推测小面板）不应报错"
    .. (ok2 and "" or ("：" .. tostring(err2))))
end

print("\n--- 按控制模式显示 BOT（武将）/ AI（武将） ---")

do
  local sc = RoomScene.create(function() end, "identity", 5, "others", { seed = 42 })
  local p2 = sc.players[2]
  local g2 = p2.general.name
  check(p2:controlMode() == "ai", "AI 托管模式下其余座位应为 ai 控制")
  check(sc:displayName(p2) == "AI（" .. g2 .. "）",
    "AI 座位面板应显示 AI（武将）（实得 " .. sc:displayName(p2) .. "）")
  check(sc:displayName(sc.human) == "你（" .. sc.human.general.name .. "）",
    "人类座位应显示 你（武将）（实得 " .. sc:displayName(sc.human) .. "）")

  -- 数字键切回规则 BOT：显示名应跟着变（控制模式运行时可切，不能写死）
  sc:keypressed("2")
  check(p2:controlMode() == "bot", "按 2 应切回规则 BOT")
  check(sc:displayName(p2) == "BOT（" .. g2 .. "）",
    "切回 BOT 后应显示 BOT（武将）（实得 " .. sc:displayName(p2) .. "）")
  sc:keypressed("2")
  check(sc:displayName(p2) == "AI（" .. g2 .. "）", "再切回 AI 应恢复 AI（武将）")

  -- 「正在思考」提示的名字与面板同源
  check(sc.agent.name_of ~= nil
      and sc.agent.name_of(p2) == sc:displayName(p2),
    "thinkingLabel 的名字解析应与 displayName 一致")
  sc:keypressed("2")
  check(sc.agent.name_of(p2) == sc:displayName(p2), "切换后两者应保持一致")

  -- 默认 ai_mode=off：全部显示 BOT（武将）
  local sc2 = RoomScene.create(function() end, "identity", 5, "off", { seed = 42 })
  check(sc2:displayName(sc2.players[2]) == "BOT（" .. sc2.players[2].general.name .. "）",
    "未开托管时应显示 BOT（武将）")
end

print(string.format("\n===== UI: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("UI 测试失败", 0) end

end)

love = real_love
if not ok then error(fatal, 0) end
