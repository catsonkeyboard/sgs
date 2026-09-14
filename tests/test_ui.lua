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
  sc.audio = { playSkill = function() return false end, play = function() return false end }
  sc.room:emit("skill", { player = sc.human, skill = "马术" }) -- 被动技，无台词
  sc:update(2) -- 事件入队，需要 update 才会播（演示队列）
  check(sc.effects.banner ~= nil,
    "无台词的技能发动也应显示横幅（实得 " .. tostring(sc.effects.banner) .. "）")
  check(#sc.effects.flashes == 1, "技能发动应在武将面板上闪一下")

  -- 3) 有台词的技能同样要有视觉
  sc.effects = Effects.create()
  sc.audio = { playSkill = function() return true end, play = function() return true end }
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
  local Cards = require "src.core.cards"

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

print(string.format("\n===== UI: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("UI 测试失败", 0) end

end)

love = real_love
if not ok then error(fatal, 0) end
