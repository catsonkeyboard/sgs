-- 牌桌场景：身份局（4 人）与 1v1 死斗
-- 与 headless 测试共用同一个 core/ 引擎——UI 只是协程驱动的另一个响应源。
-- core/ 里的同一份规则对 UI 与 BOT 生效；UI 不实现任何规则判断，
-- 只把人类玩家的鼠标点击翻译成 room:step(response)。
local class = require "src.class"
local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Cards = require "src.core.cards"
local Card = require "src.core.card"
local Room = require "src.core.room"
local Driver = require "src.core.driver"

-- 演示节奏（秒）：一条表现播完后隔多久播下一条。
-- 必须声明在文件顶部 —— update() 在它之前定义，晚声明会取到 nil。
-- 不加这层的话 driver:advance() 会同步跑完所有 BOT 行动，
-- 十几条语音和特效在同一帧一起触发，全糊在一起（用户实测反馈）。
local PRESENT_DELAY = {
  useCard = 0.42,  -- 出牌
  skill   = 0.62,  -- 发动技能（台词最长，留足时间）
  damage  = 0.34,  -- 受伤
  death   = 0.85,  -- 阵亡
  respond = 0.5,   -- 打出响应牌（闪/无懈/求桃）
  equip   = 0.42,  -- 装备上阵
  skillTarget = 0.34, -- 技能指向目标
}
local Bot = require "src.core.bot"
local Agent = require "src.core.ai.agent"
local Actions = require "src.core.ai.actions"
local Skin = require "src.ui.skin"
local Audio = require "src.ui.audio"
local Layout = require "src.ui.layout"
local Effects = require "src.ui.effects"
local SkillDesc = require "src.ui.skill_desc"
local TextFit = require "src.ui.text_fit"

local RoomScene = class("RoomScene")

local CARD_W, CARD_H = 62, 86
local PANEL_W, PANEL_H = 210, 104

-- ai_mode: "off"（无人托管）/ "others"（除你以外的座位）/ "all"（全托管，含你自己）
-- opts.seed: 固定发牌与身份的种子。测试必须传，否则每次开局局面都不同，
--            「推进到出牌阶段」「是否有距离内的目标」都会随机变化，用例随机红。
function RoomScene:init(on_exit, mode, size, ai_mode, opts)
  -- 皮肤配置（原版 skins/*.json）与音频。缺资源时全部安全降级，不影响对局。
  self.skin = Skin.create()
  self.cardImages = {}
  self.generalImages = {}
  self.kingdomImages = {}
  self.magatama = self:loadMagatamas()
  self.audio = Audio.create(self.skin)
  local engine = Engine.create()
  Standard.setup(engine)
  -- 加载 diy/ 下的原版扩展脚本；单个脚本出错不应拖垮整局，故吞掉异常
  pcall(function()
    require("src.compat.loader").loadDirectory(engine, "diy")
  end)
  mode = mode or "identity"
  local size = (mode == "identity") and (size or 5) or 2 -- 身份局默认 5 人

  -- 身份局按 size 建局（8/5/4 人）
  -- 武将**随机且不重复**：以前是固定名单取模，座位 1 永远张飞、
  -- 座位 5 又绕回张飞，导致每局武将都一样、桌位之间还重复。
  local seed = (opts and opts.seed) or (os.time() % 2147483647)
  local picks = Standard.pickGenerals(engine, Standard.makeRng(seed + 7), size)

  local players = {}
  if mode == "identity" then
    for i = 1, size do
      local is_human = (i == 1)
      local g = picks[i] or engine:getGeneral("白板武将")
      table.insert(players,
        Player.create(is_human and "你" or ("BOT·" .. g.name), g, i, is_human))
    end
  else
    table.insert(players, Player.create("你", engine:getGeneral("白板武将"), 1, true))
    table.insert(players, Player.create("BOT·乙", engine:getGeneral("剑阁武将"), 2, false))
  end

  self.mode = mode
  self.players = players
  self.human = players[1]
  self.ai_player = players[2] -- 兼容旧引用

  self.room = Room.create(engine, players)
  self.room.drawPile = Standard.buildDrawPile(seed)
  self.room.rng = Standard.makeRng(seed)
  if mode == "identity" then
    self.room:setupRoles(Standard.makeRng(seed + 1))
  end

  -- 字体与回调提前初始化：选将阶段就要用；其余对局初始化在 beginPlay
  self.font = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 15)
  self.font_mid = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 20)
  self.font_sm = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 12)
  self.on_exit = on_exit
  self.ai_mode = ai_mode or "off"
  -- 菜单「AI 思考」开关（none/low/high），覆盖 SGS_AI_REASONING；
  -- beginPlay 建 Agent 时消费。AI 推测 feed 在 beginPlay 后随时可推。
  self.ai_reasoning = opts and opts.ai_reasoning or nil
  self.aiFeed = {}   -- AI 推测变化流 {kind=belief|think, text=, turn=}
  self.aiPopup = nil -- 「AI 推测」详情弹层（点按钮列打开）

  -- ===== 开局选将（opt-in：opts.draft；默认仍走随机分将的老流程）=====
  -- 文档开局流程：身份分配 → 主公从 5 张候选里选 1、其余各从 3 张里选 1（暗置）
  -- → 同时亮出。本桌只有一名真人：真人从自己的候选池里挑，BOT 座位「秒选」
  -- （从各自候选池按种子取一张，候选池互不重复，等价于同时亮出）。
  if (opts and opts.draft) and mode == "identity" then
    local lord = self.room:getLord()
    local pools = Standard.dealCandidates(engine, Standard.makeRng(seed + 13),
      #players, lord and lord.seat or nil)
    for i, p in ipairs(players) do
      if p.is_human then
        self.draft = { candidates = pools[i], rects = nil }
      else
        self:_applyGeneral(p, pools[i][((seed + i * 31) % #pools[i]) + 1])
      end
    end
  end
  if not self.draft then self:beginPlay() end
end

-- 把选定的武将落到玩家身上（体力上限按「主公 +1」重算）
function RoomScene:_applyGeneral(p, g)
  p.general = g
  p.max_hp = g.max_hp + ((p.role == "lord") and 1 or 0)
  p.hp = p.max_hp
  p.kingdom = g.kingdom
  p.female = g.female or false
  if not p.is_human then p.name = "BOT·" .. g.name end
end

-- 选将完成 → 进入对局
function RoomScene:pickGeneral(g)
  if not self.draft then return end
  self:_applyGeneral(self.human, g)
  self.draft = nil
  self:beginPlay()
end

-- 开局选将画面（覆盖牌桌渲染；点选后 pickGeneral → beginPlay）
function RoomScene:drawDraft()
  local w = love.graphics.getDimensions()
  love.graphics.clear(0.10, 0.16, 0.10)
  local lord = self.human.role == "lord"
  love.graphics.setColor(1, 0.95, 0.8)
  love.graphics.setFont(self.font_mid)
  love.graphics.printf(lord and "你是主公 —— 从 5 张武将牌中选择一位（体力上限 +1）"
    or "从 3 张武将牌中选择你的武将", 0, 96, w, "center")
  love.graphics.setColor(0.75, 0.8, 0.75)
  love.graphics.setFont(self.font_sm)
  love.graphics.printf("其余座位已各领 3 张候选并选定 · 点击卡片确认", 0, 132, w, "center")

  local list = self.draft.candidates
  local bw, bh, gap = 168, 286, 22
  local total = #list * bw + (#list - 1) * gap
  local x0 = (w - total) / 2
  self.draft.rects = {}
  local KZ = { wei = "魏", shu = "蜀", wu = "吴", qun = "群" }
  for i, g in ipairs(list) do
    local x, y = x0 + (i - 1) * (bw + gap), 170
    self.draft.rects[i] = { x = x, y = y, w = bw, h = bh, g = g }
    love.graphics.setColor(0.16, 0.30, 0.42)
    love.graphics.rectangle("fill", x, y, bw, bh, 10, 10)
    love.graphics.setColor(0.62, 0.72, 0.82)
    love.graphics.rectangle("line", x, y, bw, bh, 10, 10)

    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(self.font_mid)
    love.graphics.printf(g.name, x, y + 12, bw, "center")
    love.graphics.setFont(self.font)
    love.graphics.printf(string.format("%s · %d 血", KZ[g.kingdom] or g.kingdom, g.max_hp),
      x, y + 43, bw, "center")

    -- 候选牌直接复用牌桌头像缓存与 Skin.generalImage，不重复加载图片。
    local avatar = self:generalImage(g)
    local ax, ay, aw, ah = x + 18, y + 70, bw - 36, 132
    if avatar then
      love.graphics.setColor(1, 1, 1)
      love.graphics.draw(avatar, ax, ay, 0, aw / avatar:getWidth(), ah / avatar:getHeight())
    else
      love.graphics.setColor(0.10, 0.18, 0.24)
      love.graphics.rectangle("fill", ax, ay, aw, ah, 6, 6)
      love.graphics.setColor(0.62, 0.68, 0.68)
      love.graphics.setFont(self.font_sm)
      love.graphics.printf("暂无头像", ax, ay + 56, aw, "center")
    end
    love.graphics.setColor(0.72, 0.62, 0.34)
    love.graphics.rectangle("line", ax, ay, aw, ah, 6, 6)

    love.graphics.setFont(self.font_sm)
    love.graphics.setColor(0.94, 0.90, 0.76)
    local shown, sy, seen = 0, y + 216, {}
    for _, sk_ in ipairs(g.skills or {}) do
      if shown >= 3 then break end
      local n = sk_.zh or sk_.name
      n = type(n) == "string" and (n:match("^(.-)·") or n) or nil
      if n and not seen[n] then
        seen[n] = true
        love.graphics.printf((sk_.lord and "[主公技] " or "") .. n, x + 6, sy,
          bw - 12, "center")
        sy = sy + 21
        shown = shown + 1
      end
    end
  end
end

-- 对局初始化（原 init 的后半段）：未启用选将时在 init 里直接调用
function RoomScene:beginPlay()
  self.room:start()

  -- ===== AI 响应源 =====
  -- 座位标成 "ai" 后，Driver 会把它的请求转给 Agent；Agent 拿不到模型输出时
  -- 先重试、再机械兜底（**不回落规则 BOT**），所以没配接口也不会卡死，
  -- 只是那几手变得很保守（不出牌、不响应）。
  -- agent 始终创建（传输层可以为空，空就等于一直机械兜底），
  -- 这样牌桌上按数字键随时能把任意座位切给 AI，不用回菜单重开。
  -- self.ai_mode 已在 init 里提前赋值（选将阶段可能用到），这里不再重置
  self.ai_error = nil
  local transport = nil
  if self.ai_mode ~= "off" then
    local ok, mod = pcall(require, "src.ui.ai_transport")
    if ok then
      -- 菜单「AI 思考」开关覆盖 SGS_AI_REASONING（Responses 协议的思维链强度）
      transport, self.ai_error = mod.fromEnv({ reasoning = self.ai_reasoning })
    else
      self.ai_error = "无法加载 AI 传输层：" .. tostring(mod)
    end
    if self.ai_mode == "others" then
      for _, p in ipairs(self.players) do
        if not p.is_human then p:setControl("ai") end
      end
    elseif self.ai_mode == "all" then
      for _, p in ipairs(self.players) do p:setControl("ai") end
      end
  end
  -- 思维链开启时单次调用 12 秒以上，Agent 自身的超时也要放宽（默认 30 秒）
  local thinking_on = self.ai_reasoning and self.ai_reasoning ~= "none"
    and self.ai_reasoning ~= ""
  self.agent = Agent.create({
    transport = transport,
    timeout = thinking_on and 140 or nil,
    -- 用 love.timer 而不是 os.time：os.time 只有秒级精度，超时判断会差一整秒
    clock = love.timer and love.timer.getTime or nil,
    on_error = function(reason)
      print(string.format("[AI] 机械兜底：%s", tostring(reason)))
    end,
    -- 身份判断变化 → 右侧「AI 推测」面板与弹层时间线
    on_beliefs = function(changes, ctx)
      local who = ctx and ctx.player and ctx.player.name or "AI"
      for _, c in ipairs(changes or {}) do
        local line = string.format("%s 判 %s：%s→%s", who, c.name, c.from, c.to)
        if ctx.reason and ctx.reason ~= "" then
          line = line .. "（" .. ctx.reason .. "）"
        end
        self:pushAIFeed("belief", line, ctx.turn)
      end
    end,
    -- 思维链摘要（思考开启时才有）→ 只进弹层时间线，不刷小面板防刷屏
    on_reasoning = function(who, summary)
      if summary and summary ~= "" then
        local s = tostring(summary):gsub("%s+", " ")
        self:pushAIFeed("think", string.format("%s 思考：%s", who, TextFit.truncate(s, 60)))
      end
    end,
  })

  self.driver = Driver.create(self.room, Bot.make(), self.agent)
  self.driver_state = self.driver:advance()

  -- 布局：优先按原版 layout.json 的间距参数推导（自适应人数），
  -- 缺少配置时 Layout 内部会退回与原来一致的固定锚点。
  -- 面板尺寸必须传给布局：排版与绘制用同一个宽度，否则右侧会被画布裁掉。
  self.layout = Layout.create(self.skin, #self.players, PANEL_W, PANEL_H)
  self.anchors = self.layout.anchors
  self.panelW, self.panelH = self.layout:panelSize()
  self.effects = Effects.create()
  self:bindPresentationHooks()

  self.msg = ""
  self.buttons = {}
  -- 演示队列：BOT 的每次出牌/发动技能/受伤/阵亡先入队，再按节奏逐个播放。
  -- 不加这层的话 driver:advance() 会**同步跑完所有 BOT 行动**，
  -- 十几条语音和特效在同一帧一起触发，全糊在一起（用户实测反馈）。
  self.presentQueue = {}
  self.presentTimer = 0

  self.selected = {}   -- 弃牌多选
  self.revealed = nil  -- askForChooseCard 候选
  self.picked = nil    -- 已选中、等待指定目标的卡牌
  self.skillPopup = nil -- 点击武将头像后显示的技能说明
end

-- ===== 布局 =====

function RoomScene:handCardRect(i)
  local x0, y0 = 40, 520
  return x0 + (i - 1) * (CARD_W + 8), y0, CARD_W, CARD_H
end

function RoomScene:cardAt(x, y)
  local hand = self.human.hand
  for idx = 1, #hand do
    local cx, cy, cw, ch = self:handCardRect(idx)
    if x >= cx and x <= cx + cw and y >= cy and y <= cy + ch then
      return hand[idx], idx
    end
  end
  return nil
end

-- 本人面板上的装备命中检测。【制衡】允许手牌与装备混合多选；装备命中
-- 沿用 panelChips 的小牌矩形（与绘制同一套），只为当前真人玩家开放点击。
function RoomScene:equipCardAt(x, y)
  local a = self:anchorOf(self.human)
  if not a then return nil end
  for _, chip in ipairs(self:panelChips(self.human, a[1], a[2])) do
    if chip.kind ~= "judge" and x >= chip.x and x <= chip.x + chip.w
      and y >= chip.y and y <= chip.y + chip.h then
      return chip.card, chip.kind
    end
  end
  return nil
end

-- 注意：本文件里**只应有这一份** anchorOf 定义（返回 {x, y} 表）。
-- 之前在文件开头还有一份返回两个数字的同名定义，被这份覆盖，
-- 导致 panelAt 里 `local px, py = self:anchorOf(p)` 拿到 (table, nil)
-- → 点牌时报 "attempt to compare table with number"。
function RoomScene:panelAt(x, y)
  for _, p in ipairs(self.players) do
    local a = self:anchorOf(p)
    local px, py = a and a[1], a and a[2]
    if px and x >= px and x <= px + PANEL_W and y >= py and y <= py + PANEL_H then
      return p
    end
  end
  return nil
end

function RoomScene:avatarRect(p)
  local a = self:anchorOf(p)
  if not a then return nil end
  return { x = a[1] + 8, y = a[2] + 24, w = 44, h = 44 }
end

function RoomScene:avatarAt(x, y)
  for _, p in ipairs(self.players or {}) do
    local r = self:avatarRect(p)
    if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      return p
    end
  end
  return nil
end

function RoomScene:openSkillPopup(p)
  if not (p and p.general) then return false end
  self.skillPopup = SkillDesc.open(p.name, p.general.name,
    SkillDesc.entriesFromSkills(p.general.skills))
  return true
end

function RoomScene:selectedCount()
  local n = 0
  for _, c in ipairs(self.human.hand) do
    if self.selected[c] then n = n + 1 end
  end
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    local c = self.human.equips[slot]
    if c and self.selected[c] then n = n + 1 end
  end
  return n
end

function RoomScene:selectedCards()
  local out = {}
  for _, c in ipairs(self.human.hand) do
    if self.selected[c] then table.insert(out, c) end
  end
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    local c = self.human.equips[slot]
    if c and self.selected[c] then table.insert(out, c) end
  end
  return out
end

-- 该玩家是否可作为当前 picked 卡牌的目标
function RoomScene:isValidTarget(p)
  if not self.picked then return false end
  if not p.alive then return false end
  local def = Cards.get(self.picked.name)
  if not def then return false end
  if def.target == "enemy" or (def.delayed and def.target ~= "self") then
    if p == self.human then return false end
  elseif p ~= self.human then
    return false
  end
  -- 距离 / 出杀次数 / 禁止技一律问引擎，UI 不自己算规则
  local ok = self.room:canUseCardOn(self.human, self.picked, p)
  return ok == true
end

-- 为什么这个目标不能用（用于给玩家一句人话提示）
function RoomScene:rejectReason(p)
  local ok, why = self.room:canUseCardOn(self.human, self.picked, p)
  if ok then return nil end
  return why or "该目标不合法"
end

-- ===== 交互 =====

function RoomScene:_step(resp)
  self.selected = {}
  self.revealed = nil
  self.picked = nil
  self.dragging = nil
  self.room:step(resp)
  self.driver:advance()
  self:_refreshButtons()
end

function RoomScene:_refreshButtons()
  local btns = {}
  local req = self.room.pending
  local function push(text, cb) table.insert(btns, { text = text, cb = cb }) end

  -- 「AI 推测」详情入口：AI 参与对局时常驻（点开看身份判断过程）
  if self.agent and self.ai_mode ~= "off" then
    push("AI 推测", function() self.aiPopup = true end)
  end

  if self.room.game_over then
    push("返回菜单", function() self.on_exit() end)
  elseif req and req.player.is_human then
    if req.type == "askForUseCard" then
      push("结束出牌", function() self:_step(nil) end)
      if self.picked then
        push("取消选择", function() self.picked = nil self.msg = "" end)
      end
    elseif req.type == "askForCard" then
      push("不出", function() self:_step(nil) end)
    elseif req.type == "askForDiscard" then
      local need, have = req.n, self:selectedCount()
      if req.any then
        -- 【制衡】类自选弃牌：任意张，随时可确认（空选 = 不发动）
        push(string.format("确认弃牌（已选 %d 张）", have), function()
          self:_step(self:selectedCards())
        end)
      else
        if have == need then
          push("确认弃牌", function() self:_step(self:selectedCards()) end)
        end
        push("自动弃牌", function()
          local order = { dodge = 1, slash = 2, fire_slash = 2, thunder_slash = 2,
            peach = 3, analeptic = 3, nullification = 4 }
          local sorted = {}
          for _, c in ipairs(self.human.hand) do table.insert(sorted, c) end
          table.sort(sorted, function(a, b)
            return (order[a.name] or 2.5) < (order[b.name] or 2.5)
          end)
          local out = {}
          for i = 1, math.min(need, #sorted) do table.insert(out, sorted[i]) end
          self:_step(out)
        end)
      end
    elseif req.type == "askForDiscardFrom" then
      -- 公开牌（装备/判定区）逐张可拆；手牌不可见，只提供「随机拆一张」。
      -- hand_only（【享乐】【雌雄双股剑】）：弃牌人自己选，可以拒绝并承担后果。
      local t = req.target
      local shown = 0
      if t and not req.hand_only then
        for _, c in ipairs(req.equip_judges or {}) do
          local cc = c
          push("拆【" .. cc:zhName() .. "】", function() self:_step(cc) end)
          shown = shown + 1
        end
      end
      if t and #t.hand > 0 then
        push(req.hand_only and "弃一张手牌" or "随机拆一张手牌", function()
          self:_step(t.hand[math.random(#t.hand)])
        end)
        shown = shown + 1
      end
      if req.hand_only or shown == 0 then
        push("不弃", function() self:_step(nil) end)
      end
    elseif req.type == "askForChooseCard" and req.allow_pass then
      -- 【顺手牵羊】：公开牌用场上方的选牌器点选；不想要时随机拿一张暗牌
      push("随机拿一张手牌", function() self:_step(nil) end)
    elseif req.type == "askForSkillInvoke" then
      -- 主动技征询：玩家自己决定发不发动
      push("发动【" .. tostring(req.skill) .. "】", function() self:_step(true) end)
      push("不发动", function() self:_step(false) end)
    elseif req.type == "askForChoice" then
      -- 选项全部摆成按钮：【借刀杀人】指定目标（玩家名）、【反间】猜花色等。
      -- 候选上限不超过 8（人数 / 花色数），摆得下。
      local list = req.choices or {}
      if #list == 0 then
        push("确定", function() self:_step(nil) end)
      else
        for _, v in ipairs(list) do
          local choice = v
          push(tostring(choice), function() self:_step(choice) end)
        end
      end
    elseif req.type == "askForGuanxing" then
      -- 【观星】：没有拖拽重排界面，但把 AI 同一套有界候选摆成按钮
      -- （原序 / 倒序 / 每张单独沉底 / 全部沉底，见 actions.lua 的 forGuanxing），
      -- 候选最多 2+5+1 = 8 个，摆得下。
      local acts = Actions.enumerate(req, self.room)
      if #acts == 0 then
        push("保持原序", function() self:_step(nil) end)
      else
        for _, a in ipairs(acts) do
          local act = a
          push(act.short or act.desc, function()
            self:_step({ up = act.up, down = act.down })
          end)
        end
      end
    else
      -- 兜底：任何未预料到的请求都必须有一个「跳过」，
      -- 否则玩家会看到提示却没有可点的按钮 —— 表现就是「界面卡死」。
      push("跳过", function() self:_step(nil) end)
    end
  end

  for i, b in ipairs(btns) do
    b.x = 1130 - 40 - i * 120
    b.y = 300
    b.w, b.h = 110, 40
  end
  -- 「退出对局」常驻：以前只有对局结束才有「返回菜单」，
  -- 中途想退出只能把游戏关掉。二次确认防误触。
  table.insert(btns, {
    text = self.confirmExit and "确认退出？" or "退出对局",
    x = 1130 - 40 - 120, y = 348, w = 110, h = 34,
    cb = function()
      if self.confirmExit then
        self.confirmExit = false
        self:_exitGame()
      else
        self.confirmExit = true
        self.msg = "再点一次【确认退出？】（或按 Esc 取消）"
      end
    end,
  })
  self.buttons = btns
end

function RoomScene:update(dt)
  -- 开局选将阶段：对局尚未开始，跳过一切推进
  if self.draft then return end
  if self.effects and dt then self.effects:update(dt) end

  -- 演示队列：一次播一条，播完等它对应的间隔再播下一条。
  -- 队列没排空前**不推进引擎**，这样 BOT 的一串行动会被摊开到若干秒里，
  -- 语音与特效不再叠在一起。
  -- 上一条台词（技能语音/阵亡语音）还没播完时队列原地等待——
  -- 否则前一个人的语音会被下一个人的行动拦腰截断（用户实测反馈）。
  if #self.presentQueue > 0
    and not (self.audio and self.audio:voiceBusy()) then
    self.presentTimer = self.presentTimer - (dt or 0)
    if self.presentTimer <= 0 then
      local e = table.remove(self.presentQueue, 1)
      self:playPresent(e)
      self.presentTimer = PRESENT_DELAY[e.kind] or 0.4
    end
    self:_refreshButtons()
    return
  end

  if not self.room.game_over then
    -- AI 思考时这里会返回 "thinking"，什么都不做即可：
    -- 下一帧再问一次，Agent 内部会继续轮询，主线程全程不阻塞。
    self.driver_state = self.driver:advance()
  end
  self:_refreshButtons()
  local req = self.room.pending
  self.revealed = (req and req.type == "askForChooseCard") and req.cards or nil
  if not (req and req.type == "askForUseCard") then
    self.picked = nil
    self.dragging = nil
  end
end

-- 数字键 1..N：把对应座位在「AI 托管」与「原本控制者」之间切换。
-- 这是「任意座位可切 AI」的现场开关——想让 AI 替你打一手，按 1；
-- 想看某个对手由 LLM 决策，按它的座位号。
local CONTROL_ZH = { human = "你来操作", bot = "规则 BOT", ai = "AI 托管" }

-- 退出对局：回到菜单。联机场景可覆盖此方法顺带断开连接
function RoomScene:_exitGame()
  if self.on_exit then self.on_exit() end
end

function RoomScene:keypressed(key)
  if self.skillPopup or self.aiPopup then
    if key == "escape" then self.skillPopup = nil self.aiPopup = nil end
    return
  end
  -- Esc 退出（二次确认）。注意：整个文件只能有**一个** keypressed，
  -- 重复定义会整体覆盖，把下面的数字键托管切换一起弄丢（踩过）。
  if key == "escape" then
    if self.confirmExit then
      self.confirmExit = false
      self.msg = "已取消退出"
    else
      self.confirmExit = true
      self.msg = "再按一次 Esc 退出对局（或点【确认退出？】）"
    end
    self:_refreshButtons()
    return
  end
  local n = tonumber(key)
  if not n or n < 1 or n > #self.players then return end
  local p = self.players[n]
  if not p then return end
  local back = p.is_human and "human" or "bot"
  local next_mode = (p:controlMode() == "ai") and back or "ai"
  p:setControl(next_mode)
  self.msg = string.format("%d 号位（%s）→ %s", n, p.name, CONTROL_ZH[next_mode] or next_mode)
  if not self.room.game_over then
    self.driver_state = self.driver:advance()
  end
  self:_refreshButtons()
end

-- 拖拽中某个面板的落点状态：ok=可落 / bad=不可落 / dead=已阵亡
function RoomScene:dropState(p)
  if not self.dragging then return nil end
  if not p.alive then return "dead" end
  return self:isValidTarget(p) and "ok" or "bad"
end

-- 拖拽时的实时提示：带攻击范围与距离，非法目标直接给出原因
function RoomScene:dragStatusText()
  if not self.dragging then return nil end
  local card = self.dragging
  local mx, my = 0, 0
  if love and love.mouse and love.mouse.getPosition then
    mx, my = love.mouse.getPosition()
  end
  local reach = self.room:attackRangeOf(self.human)
    + self.room:distanceLimitBonus(self.human, card)
  local text = string.format("攻击范围 %d", reach)
  local p = self:panelAt(mx, my)
  if p and p ~= self.human then
    text = text .. string.format(" · 到 %s 距离 %d", p.name,
      self.room:distance(self.human, p))
  end
  if not p then return text end
  if self:isValidTarget(p) then
    return text .. " · 松手对 " .. p.name .. " 使用【" .. card:zhName() .. "】"
  end
  return text .. " · " .. (self:rejectReason(p) or "该目标不合法")
end

-- 松开鼠标：把拖着的牌落到某个武将面板上。
-- 保留「点牌 → 点人」的两段式：松手在空白处只是回到已选中状态，不取消。
function RoomScene:mousereleased(x, y, button)
  if button ~= 1 or not self.dragging then return end
  local card = self.dragging
  if self.picked ~= card then self.dragging = nil return end
  local p = self:panelAt(x, y)
  if p and self:isValidTarget(p) then
    self.dragging = nil
    self:_useOn(card, p)
  elseif p then
    -- 距离不够 / 已出过杀 / 被禁止技拦下：一律给一句人话，不打出
    self.msg = self:rejectReason(p) or "该目标不合法"
  end
  self.dragging = nil
end

-- 拖拽中的牌跟着鼠标画一张半透明副本
function RoomScene:dragCardPos()
  if not self.dragging then return nil end
  if not (love and love.mouse and love.mouse.getPosition) then return nil end
  local mx, my = love.mouse.getPosition()
  return mx - CARD_W / 2, my - CARD_H / 2
end

function RoomScene:_useOn(card, target)
  self.msg = ""
  self:_step({ card = card, target = target })
end

function RoomScene:mousepressed(x, y, button)
  if button ~= 1 then return end
  -- 开局选将：点候选卡片直接选定
  if self.draft then
    for _, r in ipairs(self.draft.rects or {}) do
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        self:pickGeneral(r.g)
        return
      end
    end
    return
  end
  -- 技能说明弹层优先接管点击：关闭按钮或弹层外区域关闭，弹层内部不穿透。
  if self.skillPopup then
    if SkillDesc.shouldClose(self.skillPopup, x, y) then self.skillPopup = nil end
    return
  end
  -- 「AI 推测」弹层同规则
  if self.aiPopup then
    if self:aiPopupShouldClose(x, y) then self.aiPopup = nil end
    return
  end

  -- 武将头像在任何对局阶段都可查看（包括等待对手、演示动画期间）。
  local avatar_player = self:avatarAt(x, y)
  if avatar_player and self:openSkillPopup(avatar_player) then return end

  -- 装备/判定区小牌：点击查看卡牌说明。【制衡】/弃装混选流程除外——
  -- 那时要靠点装备小牌来选中它（下方 equipCardAt 路径）
  local pending_req = self.room.pending
  local picking_equips = pending_req and pending_req.player.is_human
    and pending_req.type == "askForDiscard" and pending_req.include_equips
  if not picking_equips and self.anchors then
    for i, p in ipairs(self.room.players or {}) do
      local a = self.anchors[i]
      if a then
        for _, chip in ipairs(self:panelChips(p, a[1], a[2])) do
          if x >= chip.x and x <= chip.x + chip.w and y >= chip.y and y <= chip.y + chip.h then
            return self:openCardPopup(p, chip)
          end
        end
      end
    end
  end

  -- 演示进行中不接受牌局操作：此时画面还在播上一段，
  -- 让玩家出牌会出现「状态已推进、画面没跟上」的错位
  if self:isPresenting() then
    self.msg = "对手行动中…"
    return
  end
  self.msg = "" -- 每次点击重新计算提示，避免上一条反馈一直挂着
  -- 点了确认按钮以外的地方 → 取消退出确认态
  if self.confirmExit then
    local hitConfirm = false
    for _, b in ipairs(self.buttons) do
      if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
        and b.text == "确认退出？" then
        hitConfirm = true
      end
    end
    if not hitConfirm then self.confirmExit = false end
  end
  for _, b in ipairs(self.buttons) do
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      b.cb()
      return
    end
  end
  local req = self.room.pending
  if not (req and req.player.is_human) or self.room.game_over then return end

  -- 五谷丰登：从展示牌中挑一张
  if req.type == "askForChooseCard" and self.revealed then
    for i, c in ipairs(self.revealed) do
      local cx = 40 + (i - 1) * (CARD_W + 8)
      if x >= cx and x <= cx + CARD_W and y >= 320 and y <= 320 + CARD_H then
        self:_step(c)
        return
      end
    end
    return
  end

  -- 已选中卡牌 → 点击/拖拽到玩家面板指定目标
  if self.picked then
    local p = self:panelAt(x, y)
    if p and self:isValidTarget(p) then
      self:_useOn(self.picked, p)
    elseif p then
      self.msg = self:rejectReason(p) or "该目标不合法"
    else
      self.picked = nil
      self.dragging = nil
    end
    return
  end

  local card = self:cardAt(x, y)
  if not card and req.type == "askForDiscard" and req.include_equips then
    card = self:equipCardAt(x, y)
  end
  if not card then return end

  if req.type == "askForUseCard" then
    local def = Cards.get(card.name)
    if not def then self.msg = "这张牌暂无规则" return end
    local needs_target = (def.target == "enemy") or (def.delayed and def.target ~= "self")
    if needs_target then
      self.picked = card
      -- 先试算有没有合法目标：没有就直接说原因，
      -- 免得玩家选中一张根本打不出去的牌（距离/次数限制）。
      local legal, why = 0, nil
      for _, q in ipairs(self.players) do
        if q ~= self.human and q.alive then
          local ok, reason = self.room:canUseCardOn(self.human, card, q)
          if ok then legal = legal + 1 else why = why or reason end
        end
      end
      if legal == 0 then
        self.picked = nil
        self.msg = why or "没有合法目标"
        return
      end
      self.dragging = card -- 支持按住拖到武将身上
      self.msg = "已选中【" .. card:zhName() .. "】，点击或拖到目标角色（" .. legal .. " 个可选）"
    else
      self:_useOn(card, self.human)
    end

  elseif req.type == "askForCard" then
    local wanted = req.card_name
    if card.name == wanted or (wanted == "peach" and card.name == "analeptic") then
      self.msg = ""
      self:_step(card)
    else
      self.msg = "请打出【" .. (Card.ZH[wanted] or wanted) .. "】或点【不出】"
    end

  elseif req.type == "askForDiscard" then
    local have = self:selectedCount()
    if self.selected[card] then
      self.selected[card] = nil
    elseif have < req.n then
      self.selected[card] = true
    else
      self.msg = "已选够 " .. req.n .. " 张，点【确认弃牌】"
    end
  end
end

-- ===== 渲染 =====

-- 体力：有原版勾玉素材就用勾玉（满 3 / 空 0），否则退回圆点
local function drawHp(x, y, hp, max_hp, scene)
  local full, empty = nil, nil
  if scene and scene.skin and scene.magatama then
    full = scene.magatama.full
    empty = scene.magatama.empty
  end
  if full and empty then
    local s = 13
    local scale = s / full:getHeight()
    for i = 1, max_hp do
      local img = (i <= hp) and full or empty
      love.graphics.setColor(1, 1, 1)
      love.graphics.draw(img, x + (i - 1) * (s + 2), y - s, 0, scale, scale)
    end
    return
  end
  for i = 1, max_hp do
    if i <= hp then love.graphics.setColor(0.85, 0.15, 0.1)
    else love.graphics.setColor(0.25, 0.25, 0.25) end
    love.graphics.circle("fill", x + (i - 1) * 17, y, 6)
  end
end

local function faceColor(c)
  if not c then return 0.5, 0.5, 0.5 end
  local red = c:isRed()
  return red and 0.8 or 0.1, red and 0.1 or 0.1, red and 0.1 or 0.1
end

-- 卡图：有原版资源就画真图，没有（或加载失败）退回色块。
-- 图片缓存挂在 scene 上，避免每帧重复解码。
local function cardImage(scene, c)
  if not (scene and scene.skin and c) then return nil end
  local cache = scene.cardImages
  if not cache then return nil end
  if cache[c.name] ~= nil then return cache[c.name] or nil end
  local rel = scene.skin:cardImage(c.name)
  local img = nil
  if rel then
    local path = scene.skin:path(rel)
    if path and love.graphics then
      local ok, loaded = pcall(love.graphics.newImage, path)
      if ok then img = loaded end
    end
  end
  cache[c.name] = img or false -- 记 false 表示「已知不可用」
  return img
end

local function drawCard(x, y, w, h, c, font, font_sm, scene)
  local img = scene and cardImage(scene, c)
  if img then
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, x, y, 0, w / img:getWidth(), h / img:getHeight())
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
    -- 真图上叠一行牌名，保证小尺寸下也能认出来
    love.graphics.setFont(font_sm)
    love.graphics.printf(c:zhName(), x, y + h - 18, w, "center")
    return
  end
  love.graphics.setColor(0.96, 0.94, 0.88)
  love.graphics.rectangle("fill", x, y, w, h, 6, 6)
  love.graphics.setColor(0, 0, 0)
  love.graphics.rectangle("line", x, y, w, h, 6, 6)
  love.graphics.setColor(faceColor(c))
  love.graphics.setFont(font_sm)
  love.graphics.print(c:suitString() .. c.number, x + 5, y + 4)
  love.graphics.setColor(0, 0, 0)
  love.graphics.setFont(font)
  love.graphics.printf(c:zhName(), x, y + h / 2 - 10, w, "center")
end

-- 飞牌动画的绘制闭包：特效层只给轨迹插值，牌面用与手牌同一套 drawCard
local function flyCardFn(scene, c)
  return function(x, y, w, h, _alpha)
    drawCard(x, y, w, h, c, scene.font, scene.font_sm, scene)
  end
end

local ROLE_COLOR = {
  lord = { 0.95, 0.75, 0.2 },
  loyalist = { 0.35, 0.65, 0.95 },
  rebel = { 0.9, 0.3, 0.25 },
  renegade = { 0.55, 0.55, 0.6 },
}

-- 勾玉（体力图标）：加载失败就返回 nil，drawHp 会退回圆点画法
function RoomScene:loadMagatamas()
  if not (self.skin and love.graphics) then return nil end
  local function load(kind)
    local rel = self.skin:magatamaImage(kind)
    if not rel then return nil end
    local path = self.skin:path(rel)
    if not path then return nil end
    local ok, img = pcall(love.graphics.newImage, path)
    return ok and img or nil
  end
  local full, empty = load(3), load(0)
  if full and empty then return { full = full, empty = empty } end
  return nil
end

-- 把音频与动效挂到引擎的表现层事件上。
-- 音效键名沿用原版 audio.json；缺失时 Audio 内部静默降级。
-- 把音频与动效挂到引擎的表现层事件上。
-- 音效键名沿用原版 audio.json；缺失时 Audio 内部静默降级。
--
-- 关键：这里**不直接播放**，而是入队，由 update 按节奏逐个播放。
-- 引擎是同步推进的（一次 advance 可能跑完十几个 BOT 行动），
-- 直接播就会全部叠在一起。
function RoomScene:enqueuePresent(kind, d)
  table.insert(self.presentQueue, { kind = kind, data = d })
end

function RoomScene:isPresenting()
  return #self.presentQueue > 0
end

-- 演示队列为空之前不接受玩家操作，避免状态与画面错位
function RoomScene:playPresent(e)
  local audio, fx = self.audio, self.effects
  local d = e.data
  if e.kind == "useCard" then
    if d and d.card then
      if audio then audio:playCard(d.card.name, d.from and d.from.female and "female" or "male") end
      if d.from and fx then
        fx:showBanner(string.format("%s 使用【%s】", d.from.name, d.card:zhName()))
      end
      self:presentCardFlight(d.card, d.from, d.to)
    end
  elseif e.kind == "respond" then
    -- 任何人打出的响应牌（杀被闪、无懈、濒死求桃……）：音效 + 飞牌 + 面板高亮
    if d and d.card and d.player then
      if audio then
        audio:playCard(d.card.name, d.player.female and "female" or "male")
      end
      if fx then
        fx:showBanner(string.format("%s 打出【%s】", d.player.name, d.card:zhName()),
          { 0.75, 0.9, 1 })
        local a = self:anchorOf(d.player)
        if a then
          fx:flashPanel(a[1], a[2], self.panelW or PANEL_W, self.panelH or PANEL_H,
            { 0.6, 0.85, 1 })
        end
      end
      -- 响应牌朝牌桌中央飞（是替谁打的这里拿不到，飞向中央最不误导）
      local sx, sy = self:launchPoint(d.player)
      local cx, cy = self:centerPoint()
      if fx and sx then
        fx:fly(flyCardFn(self, d.card), sx, sy, cx, cy, CARD_W * 0.9, CARD_H * 0.9)
      end
    end
  elseif e.kind == "equip" then
    -- 装备上阵：武器/防具/马各有音效，牌从手里飞到自己面板
    if d and d.card and d.player then
      if audio then audio:playEquip(d.slot) end
      if fx then
        fx:showBanner(string.format("%s 装备【%s】", d.player.name, d.card:zhName()),
          { 0.8, 0.95, 0.75 })
        local a = self:anchorOf(d.player)
        if a then
          fx:flashPanel(a[1], a[2], self.panelW or PANEL_W, self.panelH or PANEL_H,
            { 0.65, 0.95, 0.65 })
        end
      end
      local px, py = self:panelCenter(d.player)
      local sx, sy = self:launchPoint(d.player)
      if fx and px and sx then
        fx:fly(flyCardFn(self, d.card), sx, sy, px, py, CARD_W * 0.9, CARD_H * 0.9)
      end
    end
  elseif e.kind == "skillTarget" then
    -- 技能指定目标：施法者 → 目标画一条指向箭头，并高亮目标面板
    if d and d.player and d.target and fx then
      local x1, y1 = self:panelCenter(d.player)
      local x2, y2 = self:panelCenter(d.target)
      if x1 and x2 then fx:arrow(x1, y1, x2, y2) end
      local a = self:anchorOf(d.target)
      if a then
        fx:flashPanel(a[1], a[2], self.panelW or PANEL_W, self.panelH or PANEL_H,
          { 0.95, 0.85, 0.35 })
      end
    end
  elseif e.kind == "damage" then
    if d and d.to then
      if audio then audio:play("injure") end
      local a = self:anchorOf(d.to)
      if a and fx then
        fx:float(a[1] + (self.panelW or 210) / 2, a[2] + 30, "-" .. tostring(d.n))
      end
      -- 被动命中也画指向（谁打的我）：伤害来源 → 受害者
      if d.from and fx then
        local x1, y1 = self:panelCenter(d.from)
        local x2, y2 = self:panelCenter(d.to)
        if x1 and x2 then fx:arrow(x1, y1, x2, y2, { 0.95, 0.3, 0.25 }) end
      end
    end
  elseif e.kind == "skill" then
    if not d then return end
    if audio then audio:playSkill(d.skill) end
    if d.player then
      if fx then fx:showBanner(string.format("%s 发动【%s】", d.player.name, tostring(d.skill)), { 0.95, 0.85, 0.35 }) end
      local a = self:anchorOf(d.player)
      if a and fx then
        fx:flashPanel(a[1], a[2], self.panelW or 210, self.panelH or 96, { 0.95, 0.85, 0.35 })
      end
    end
  elseif e.kind == "death" then
    if d and d.player then
      if audio then
        -- 阵亡语音按台词处理：播完前演示队列不推进
        if not (d.key and audio:playVoice(d.key)) then audio:playVoice("death") end
      end
      if fx then fx:showBanner(string.format("%s 阵亡", d.player.name), { 0.9, 0.3, 0.25 }) end
    end
  end
end

-- 面板中心（anchorOf 找不到座位时返回 nil，调用方跳过动画即可）
function RoomScene:panelCenter(p)
  local a = self:anchorOf(p)
  if not a then return nil end
  return a[1] + (self.panelW or PANEL_W) / 2, a[2] + (self.panelH or PANEL_H) / 2
end

-- 飞牌起点：真人从手牌区出手，BOT 从面板中心出手
function RoomScene:launchPoint(p)
  if not p then return nil end
  if p == self.human and not self.draft and #(p.hand or {}) > 0
    and self.handCardRect then
    local x, y = self:handCardRect(math.ceil(#p.hand / 2))
    return x + CARD_W / 2, y + CARD_H / 2
  end
  return self:panelCenter(p)
end

-- 屏幕中心（响应牌的落点；headless 下给一个兜底尺寸）
function RoomScene:centerPoint()
  local w, h = 1130, 650
  if love and love.graphics and love.graphics.getDimensions then
    local ok, a, b = pcall(love.graphics.getDimensions)
    if ok and a then w, h = a, b or h end
  end
  return w / 2, h / 2
end

-- 出牌的指向与飞牌：装备牌飞回自己面板，其余按目标逐个画箭头
function RoomScene:presentCardFlight(card, from, targets)
  local fx = self.effects
  if not (fx and from) then return end
  local def = card.name and Cards.get(card.name) or nil
  local is_equip = def ~= nil and def.ctype == Card.Type.Equip
  local list = (targets and #targets > 0) and targets or {}
  if is_equip then list = { from } end -- 装备牌：目标是出牌人自己

  local sx, sy = self:launchPoint(from)
  local tx, ty
  if is_equip or #list == 0 then
    tx, ty = self:panelCenter(from)
    if not is_equip and #list == 0 then tx, ty = self:centerPoint() end
  else
    tx, ty = self:panelCenter(list[1])
  end
  if sx and tx then
    fx:fly(flyCardFn(self, card), sx, sy, tx, ty, CARD_W * 0.9, CARD_H * 0.9)
  end
  -- 多目标（AOE）逐个画指向，封顶 6 条防刷屏
  for i, t in ipairs(list) do
    if i > 6 then break end
    if not is_equip and t ~= from then
      local x1, y1 = self:panelCenter(from)
      local x2, y2 = self:panelCenter(t)
      if x1 and x2 then fx:arrow(x1, y1, x2, y2, { 1, 0.9, 0.55 }) end
    end
  end
end

function RoomScene:bindPresentationHooks()
  local room = self.room
  if not room then return end
  for _, kind in ipairs({ "useCard", "damage", "skill", "death",
                          "respond", "equip", "skillTarget" }) do
    room:onEvent(kind, function(d) self:enqueuePresent(kind, d) end)
  end
end

function RoomScene:anchorOf(p)
  if not (self.anchors and p) then return nil end
  for i, q in ipairs(self.room.players or {}) do
    if q == p then return self.anchors[i] end
  end
  return nil
end

-- 势力图标：image/kingdom/icon/<kingdom>.png
function RoomScene:kingdomIcon(p)
  if not (self.skin and p and p.kingdom) then return nil end
  local cache = self.kingdomImages
  if not cache then return nil end
  local k = p.kingdom
  if cache[k] ~= nil then return cache[k] or nil end
  local img = nil
  local rel = self.skin:kingdomImage(k)
  if rel and love.graphics then
    local path = self.skin:path(rel)
    if path then
      local ok, loaded = pcall(love.graphics.newImage, path)
      if ok then img = loaded end
    end
  end
  cache[k] = img or false
  return img
end

-- 武将头像：按 general.key（拼音）在原版 image/generals/avatar 下找。
-- 接收武将对象，供选将卡与牌桌面板共用同一缓存。
function RoomScene:generalImage(general)
  if not (self.skin and general) then return nil end
  local cache = self.generalImages
  if not cache then return nil end
  local key = general.key or general.name
  if cache[key] ~= nil then return cache[key] or nil end
  local img = nil
  local rel = self.skin:generalImage(key)
  if rel and love.graphics and love.graphics.newImage then
    local path = self.skin:path(rel)
    if path then
      local ok, loaded = pcall(love.graphics.newImage, path)
      if ok then img = loaded end
    end
  end
  cache[key] = img or false
  return img
end

function RoomScene:generalAvatar(p)
  return p and self:generalImage(p.general) or nil
end

-- 装备/判定区小牌的配色（边框色）：武器金、防具蓝、马橙/绿、判定红
local CHIP_COLOR = {
  weapon = { 0.82, 0.62, 0.25 },
  armor = { 0.45, 0.65, 0.85 },
  offensive_horse = { 0.85, 0.55, 0.30 },
  defensive_horse = { 0.45, 0.75, 0.50 },
  judge = { 0.85, 0.35, 0.30 },
}

-- 马匹小牌后缀：进攻马 -1（你算别人的距离），防御马 +1（别人算你的距离）
local CHIP_SLOT_TAG = { offensive_horse = "-1", defensive_horse = "+1" }

-- 装备/判定小牌网格：2 列 × N 行；格内 = 小卡图(11×15) + 牌名/距离
local CHIP_W, CHIP_H = 100, 17
local CHIP_IMG_W, CHIP_IMG_H = 11, 15

-- 粗略估文本像素宽：UTF-8 里中日韩字符占 3 字节按 13px，其余按 7px
local function chipTextW(s)
  local cjk = select(2, s:gsub("[^\128-\191]", ""))
  local ascii = #s - cjk * 3
  return cjk * 13 + ascii * 7
end

function RoomScene:drawPlayerPanel(p, x, y, highlighted)
  love.graphics.setColor(highlighted and 0.18 or 0.12,
    highlighted and 0.30 or 0.16, highlighted and 0.18 or 0.12)
  love.graphics.rectangle("fill", x, y, PANEL_W, PANEL_H, 8, 8)
  if highlighted then
    love.graphics.setColor(0.95, 0.8, 0.25)
    love.graphics.rectangle("line", x, y, PANEL_W, PANEL_H, 8, 8)
  end
  if self.skillPopup and self.skillPopup.player_name == p.name then
    love.graphics.setColor(0.95, 0.72, 0.22)
    love.graphics.rectangle("line", x + 6, y + 22, 48, 48, 5, 5)
  end

  -- 势力图标（有资源就画，没有就不画，不占版面）
  local kimg = self:kingdomIcon(p)
  if kimg then
    local s = 16
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(kimg, x + PANEL_W - 60, y + 26, 0, s / kimg:getWidth(), s / kimg:getHeight())
  end

  -- 武将头像（有原版资源时画真图，否则退回纯文字）
  local avatar = self:generalAvatar(p)
  if avatar then
    local aw, ah = 44, 44
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(avatar, x + 8, y + 24, 0, aw / avatar:getWidth(), ah / avatar:getHeight())
    love.graphics.setColor(0.6, 0.5, 0.3)
    love.graphics.rectangle("line", x + 8, y + 24, aw, ah, 4, 4)
  end

  love.graphics.setFont(self.font_sm)
  love.graphics.setColor(1, 0.92, 0.75)
  love.graphics.print(p.name .. "（" .. (p.general and p.general.name or "-") .. "）", x + 8, y + 6)

  -- 身份：本人、主公、已阵亡者可见
  if p.role and (p == self.human or p.role_revealed or not p.alive) then
    local c = ROLE_COLOR[p.role] or { 0.7, 0.7, 0.7 }
    love.graphics.setColor(c[1], c[2], c[3])
    love.graphics.rectangle("fill", x + PANEL_W - 46, y + 5, 40, 18, 4, 4)
    love.graphics.setColor(0, 0, 0)
    love.graphics.printf(Player.ROLE_ZH[p.role] or p.role, x + PANEL_W - 46, y + 8, 40, "center")
  else
    love.graphics.setColor(0.45, 0.45, 0.45)
    love.graphics.rectangle("fill", x + PANEL_W - 46, y + 5, 40, 18, 4, 4)
    love.graphics.setColor(0, 0, 0)
    love.graphics.printf("?", x + PANEL_W - 46, y + 8, 40, "center")
  end

  drawHp(x + 12, y + 38, p.hp, p.max_hp, self)

  love.graphics.setFont(self.font_sm)
  love.graphics.setColor(p.alive and 0.7 or 0.4, 0.75, 0.7)
  love.graphics.print("手牌 × " .. #p.hand .. (p.alive and "" or " · 已阵亡"), x + 12, y + 56)
  if p.chained then
    love.graphics.setColor(0.85, 0.6, 0.2)
    love.graphics.print("连环", x + 110, y + 56)
  end

  -- 装备与判定区：小卡图 + 牌名（马匹带距离标注），2 列 × 2 行，
  -- 绘制与点击命中共用 panelChips 给出的同一套矩形
  for _, chip in ipairs(self:panelChips(p, x, y)) do
    love.graphics.setColor(0.10, 0.09, 0.07, 0.95)
    love.graphics.rectangle("fill", chip.x, chip.y, chip.w, chip.h, 3, 3)
    local border = (self.selected and self.selected[chip.card])
      and { 1, 0.82, 0.18 } or CHIP_COLOR[chip.kind] or { 0.6, 0.6, 0.6 }
    love.graphics.setColor(border[1], border[2], border[3], 0.9)
    love.graphics.rectangle("line", chip.x, chip.y, chip.w, chip.h, 3, 3)
    local tx = chip.x + 4
    if chip.img then
      love.graphics.setColor(1, 1, 1)
      love.graphics.draw(chip.img, chip.x + 2, chip.y + 1, 0,
        CHIP_IMG_W / chip.img:getWidth(), CHIP_IMG_H / chip.img:getHeight())
      love.graphics.setColor(0.35, 0.3, 0.2)
      love.graphics.rectangle("line", chip.x + 2, chip.y + 1, CHIP_IMG_W, CHIP_IMG_H)
      tx = chip.x + 15
    end
    love.graphics.setColor(0.95, 0.93, 0.85)
    love.graphics.setFont(self.font_sm)
    love.graphics.print(chip.text, tx, chip.y + 1)
  end
end

-- 某玩家面板底部的小牌列表（装备 + 判定区延时锦囊）。
-- 每格 = 小卡图（有卡图时）+ 牌名（马匹带 -1/+1 距离标注）。
-- ax/ay 是面板左上角；返回 { x,y,w,h,text,card,kind,img }，供绘制与点击命中。
function RoomScene:panelChips(p, ax, ay)
  local chips = {}
  if not p then return chips end
  local items = {}
  for _, slot in ipairs({ "weapon", "armor", "offensive_horse", "defensive_horse" }) do
    local c = p.equips and p.equips[slot]
    if c then
      items[#items + 1] = { text = c:zhName() .. (CHIP_SLOT_TAG[slot] or ""),
        card = c, kind = slot }
    end
  end
  for _, c in ipairs(p.judges or {}) do
    items[#items + 1] = { text = c:zhName(), card = c, kind = "judge" }
  end
  for i, t in ipairs(items) do
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local img = cardImage(self, t.card)
    local tw = chipTextW(t.text) + (img and 16 or 8)
    chips[#chips + 1] = {
      x = ax + 5 + col * (CHIP_W + 1),
      y = ay + 68 + row * (CHIP_H + 1),
      w = math.min(CHIP_W, tw), h = CHIP_H,
      text = t.text, card = t.card, kind = t.kind, img = img or false,
    }
  end
  return chips
end

-- 点装备/判定小牌 → 弹出这张牌的说明（复用技能弹层渲染）
function RoomScene:openCardPopup(p, chip)
  local def = chip.card and chip.card.name and Cards.get(chip.card.name)
  local desc = def and def.desc
  if not desc and chip.kind == "offensive_horse" then
    desc = "你计算与其他角色的距离时 -1。"
  elseif not desc and chip.kind == "defensive_horse" then
    desc = "其他角色计算与你的距离时 +1。"
  end
  self.skillPopup = SkillDesc.open(p.name, chip.kind == "judge" and "判定区" or "装备区",
    { { name = chip.card:zhName(), desc = desc or "暂无详细说明。" } })
  self.skillPopup.subtitle = "卡牌说明"
  return true
end

-- ===== AI 推测展示：右侧常驻小面板 + 「AI 推测」详情弹层 =====
-- 文本截断走 src/ui/text_fit.lua（按 UTF-8 完整字符截，
-- 字节级 sub 会把中文劈开导致 print 抛 Invalid UTF-8）

-- 推一条 AI 动态进 feed（kind: "belief" 身份判断变化 / "think" 思维链摘要）。
-- 上限 40 条，旧的先丢——这里只要「过程流」，完整状态看弹层。
function RoomScene:pushAIFeed(kind, text, turn)
  self.aiFeed = self.aiFeed or {}
  table.insert(self.aiFeed, { kind = kind, text = tostring(text), turn = turn })
  while #self.aiFeed > 40 do table.remove(self.aiFeed, 1) end
end

-- 右侧常驻小面板（920,400 起，约 200×190）：只显示身份判断变化（最近 5 条），
-- 思维链摘要进弹层时间线，不在这刷屏。
function RoomScene:drawAIPanel()
  if not (self.agent and self.ai_mode ~= "off") then return end
  local x, y, w, h = 920, 400, 200, 190
  love.graphics.setColor(0.05, 0.08, 0.05, 0.72)
  love.graphics.rectangle("fill", x, y, w, h, 8, 8)
  love.graphics.setColor(0.82, 0.68, 0.30, 0.5)
  love.graphics.rectangle("line", x, y, w, h, 8, 8)
  love.graphics.setColor(1, 0.90, 0.58)
  love.graphics.setFont(self.font_sm)
  love.graphics.print("AI 推测", x + 10, y + 8)

  local beliefs = {}
  for _, e in ipairs(self.aiFeed or {}) do
    if e.kind == "belief" then beliefs[#beliefs + 1] = e end
  end
  if #beliefs == 0 then
    love.graphics.setColor(0.6, 0.65, 0.6)
    love.graphics.print("AI 还没有身份判断", x + 10, y + 30)
  else
    local shown = math.min(5, #beliefs)
    for i = 0, shown - 1 do
      local e = beliefs[#beliefs - shown + 1 + i]
      love.graphics.setColor(0.88, 0.90, 0.84)
      -- 超宽截断（按完整字符）：小面板只有 180px 可用宽
      love.graphics.print(TextFit.fit(e.text, w - 20), x + 10, y + 28 + i * 16)
    end
  end
  love.graphics.setColor(0.55, 0.6, 0.55)
  love.graphics.print("点【AI 推测】看完整过程", x + 10, y + h - 20)
end

-- 「AI 推测」弹层的布局（居中模态，与技能弹层同风格）
function RoomScene:aiPopupLayout()
  local sw, sh = love.graphics.getDimensions()
  local w = math.min(720, sw - 80)
  local lines = self:aiPopupLines()
  local h = math.min(sh - 40, 96 + #lines * 17)
  local x, y = (sw - w) / 2, (sh - h) / 2
  return { x = x, y = y, w = w, h = h,
    close = { x = x + w - 94, y = y + 16, w = 72, h = 30 } }
end

function RoomScene:aiPopupShouldClose(x, y)
  local box = self:aiPopupLayout()
  local c = box.close
  if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then return true end
  return x < box.x or x > box.x + box.w or y < box.y or y > box.y + box.h
end

-- 弹层内容行（实时读 agent.memories，弹层开着时新判断也会出现）：
-- 区块 A 各 AI 当前判断 → 区块 B 变化时间线（含思维链摘要）→ 区块 C 长期观察
function RoomScene:aiPopupLines()
  local lines = {}
  local agent = self.agent
  if not (agent and agent.memories) then return { "（AI 未参与对局）" } end
  local seats = {}
  for k in pairs(agent.memories) do seats[#seats + 1] = k end
  table.sort(seats, function(a, b) return tostring(a) < tostring(b) end)

  local function playerNameOf(key)
    for _, p in ipairs(self.players or {}) do
      if tostring(p.seat) == tostring(key) or p.name == key then return p.name end
    end
    return "座位" .. tostring(key)
  end

  if #seats > 0 then
    lines[#lines + 1] = "◆ 当前判断"
    for _, seat in ipairs(seats) do
      local mem = agent.memories[seat]
      local who = playerNameOf(seat)
      local keys = {}
      for k in pairs(mem.beliefs or {}) do keys[#keys + 1] = k end
      table.sort(keys)
      if #keys == 0 then
        lines[#lines + 1] = string.format("  %s：暂无判断", who)
      else
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. mem.beliefs[k] end
        lines[#lines + 1] = string.format("  %s：%s", who, table.concat(parts, "，"))
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "◆ 判断过程"
  -- 时间线：feed 里 belief + think 混排（含理由与思维链摘要），最近 18 条
  local feed = self.aiFeed or {}
  local shown = math.min(18, #feed)
  if shown == 0 then
    lines[#lines + 1] = "  （还没有变化记录）"
  else
    for i = #feed - shown + 1, #feed do
      local e = feed[i]
      local prefix = e.kind == "think" and "  ◇ " or "  · "
      local turnTag = e.turn and ("[第" .. tostring(e.turn) .. "轮] ") or ""
      lines[#lines + 1] = prefix .. turnTag .. e.text
    end
  end

  local any_note = false
  for _, seat in ipairs(seats) do
    local mem = agent.memories[seat]
    if mem.notes and mem.notes ~= "" then
      if not any_note then lines[#lines + 1] = "" lines[#lines + 1] = "◆ AI 长期观察" any_note = true end
      lines[#lines + 1] = string.format("  %s：%s", playerNameOf(seat), mem.notes)
    end
  end
  return lines
end

function RoomScene:drawAIPopup()
  if not self.aiPopup then return end
  local sw, sh = love.graphics.getDimensions()
  local box = self:aiPopupLayout()
  love.graphics.setColor(0, 0, 0, 0.68)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  love.graphics.setColor(0.10, 0.14, 0.10, 0.98)
  love.graphics.rectangle("fill", box.x, box.y, box.w, box.h, 12, 12)
  love.graphics.setColor(0.82, 0.68, 0.30)
  love.graphics.rectangle("line", box.x, box.y, box.w, box.h, 12, 12)
  love.graphics.setFont(self.font_mid)
  love.graphics.setColor(1, 0.90, 0.58)
  love.graphics.print("AI 身份推测", box.x + 24, box.y + 16)
  love.graphics.setFont(self.font_sm)
  love.graphics.setColor(0.72, 0.78, 0.70)
  love.graphics.print("各 AI 座位对全场身份的判断与变化过程", box.x + 24, box.y + 47)

  love.graphics.setFont(self.font_sm)
  local max_fit = math.floor((box.h - 96) / 17)
  local lines = self:aiPopupLines()
  for i, ln in ipairs(lines) do
    if i > max_fit then
      love.graphics.setColor(0.6, 0.62, 0.58)
      love.graphics.print("……（还有 " .. (#lines - max_fit) .. " 行，关闭后等新判断再看）",
        box.x + 24, box.y + 78 + (i - 1) * 17)
      break
    end
    love.graphics.setColor(0.90, 0.92, 0.86)
    love.graphics.print(TextFit.fit(ln, box.w - 48), box.x + 24, box.y + 78 + (i - 1) * 17)
  end

  local c = box.close
  love.graphics.setColor(0.28, 0.38, 0.26)
  love.graphics.rectangle("fill", c.x, c.y, c.w, c.h, 6, 6)
  love.graphics.setColor(1, 1, 1)
  love.graphics.printf("关闭", c.x, c.y + 7, c.w, "center")
end

-- 桌面背景 + 底部仪表盘框体（有原版素材就画，没有就保持纯色）
function RoomScene:drawBackground()
  if not self.skin then return end
  local img = self.tableBg
  if img == nil then -- 未尝试过才去加载
    self.tableBg = false
    local rel = self.skin:tableBackground()
    if rel and love.graphics then
      local path = self.skin:path(rel)
      if path then
        local ok, loaded = pcall(love.graphics.newImage, path)
        if ok then self.tableBg = loaded end
      end
    end
  end
  if self.tableBg and love.graphics then
    local w, h = love.graphics.getDimensions()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self.tableBg, 0, 0, 0, w / self.tableBg:getWidth(),
      h / self.tableBg:getHeight())
  end

  -- 底部仪表盘底框
  if self.dashBase == nil then
    self.dashBase = false
    local rel = self.skin:frame("dashboardRightBase") or self.skin:frame("dashboardMiddleFrame")
    if rel and love.graphics then
      local path = self.skin:path(rel)
      if path then
        local ok, loaded = pcall(love.graphics.newImage, path)
        if ok then self.dashBase = loaded end
      end
    end
  end
  if self.dashBase then
    local w, h = love.graphics.getDimensions()
    local dh = self.dashBase:getHeight()
    love.graphics.setColor(1, 1, 1, 0.85)
    love.graphics.draw(self.dashBase, w / 2 - self.dashBase:getWidth() / 2, h - dh - 40)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function RoomScene:draw()
  -- 开局选将阶段：覆盖牌桌渲染，只画选将画面
  if self.draft then self:drawDraft() return end
  love.graphics.clear(0.09, 0.13, 0.09)
  local room = self.room

  self:drawBackground()

  -- 拖拽落点提示：合法目标描绿边，鼠标悬停的非法目标描红边。
  -- 用叠加层而不是改 drawPlayerPanel，避免动那个近百行的函数。
  local mx, my = 0, 0
  if love and love.mouse and love.mouse.getPosition then
    mx, my = love.mouse.getPosition()
  end

  for _, p in ipairs(self.players) do
    local a = self:anchorOf(p)
    local x, y = a[1], a[2]
    local hl = (self.picked ~= nil) and self:isValidTarget(p) and (p ~= self.human)
    self:drawPlayerPanel(p, x, y, hl)

    if self.dragging then
      local st = self:dropState(p)
      local hover = mx >= x and mx <= x + PANEL_W and my >= y and my <= y + PANEL_H
      local setWidth = love.graphics.setLineWidth -- 打桩的 love 可能没有，需判空
      if st == "ok" then
        love.graphics.setColor(0.25, 0.85, 0.35, 0.95)
        if setWidth then setWidth(hover and 4 or 2) end
        love.graphics.rectangle("line", x, y, PANEL_W, PANEL_H, 8, 8)
        if setWidth then setWidth(1) end
      elseif hover and st == "bad" then
        love.graphics.setColor(0.92, 0.28, 0.22, 0.95)
        if setWidth then setWidth(4) end
        love.graphics.rectangle("line", x, y, PANEL_W, PANEL_H, 8, 8)
        if setWidth then setWidth(1) end
      end
    end
  end

  -- 中部：回合 / 牌堆
  love.graphics.setColor(0.8, 0.85, 0.8)
  love.graphics.setFont(self.font)
  local cur = room.players[room.current_seat]
  love.graphics.print(string.format("第 %d 回合 · 行动：%s · 阶段：%s",
    room.turn_count, cur and cur.name or "-", self.human.phase or "-"), 460, 290)
  love.graphics.print(string.format("摸牌堆 %d · 弃牌堆 %d",
    #room.drawPile, #room.discardPile), 460, 315)
  if self.mode == "identity" then
    love.graphics.setColor(0.6, 0.65, 0.6)
    love.graphics.print("身份局：主公与忠臣 vs 反贼（内奸独立取胜）", 460, 340)
  end

  -- 动效（浮动伤害数字 / 出牌横幅）
  if self.effects then
    local w, h = love.graphics.getDimensions()
    self.effects:draw(w, h, self.font, self.font_mid)
  end

  -- 五谷丰登展示区
  if self.revealed and #self.revealed > 0 then
    love.graphics.setColor(0.9, 0.85, 0.6)
    love.graphics.print("五谷丰登：点击一张收入手中", 40, 298)
    for i, c in ipairs(self.revealed) do
      drawCard(40 + (i - 1) * (CARD_W + 8), 320, CARD_W, CARD_H, c,
        self.font, self.font_sm, self)
    end
  end

  -- 手牌
  love.graphics.setFont(self.font)
  for idx = 1, #self.human.hand do
    local c = self.human.hand[idx]
    if c == nil then break end
    local x, y = self:handCardRect(idx)
    local lifted = ((self.selected[c] or self.picked == c) and 14 or 0)
    -- 用 drawCard 画：有卡图就画真图（assets/image/card/*.png），
    -- 没有才退化成白底+文字。以前这里是一段**独立的手写绘制**，
    -- 只画白底矩形，所以手牌永远没有卡图（五谷丰登的展示牌反而有）。
    drawCard(x, y - lifted, CARD_W, CARD_H, c, self.font, self.font_sm, self)
    -- 选中/拖拽的高亮叠在卡图之上
    if self.picked == c then
      love.graphics.setColor(0.95, 0.8, 0.2)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    elseif self.selected[c] then
      love.graphics.setColor(0.95, 0.75, 0.2)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    end
  end

  -- 拖拽中的牌：跟鼠标画一张副本（放在手牌之后，保证在最上层）
  local dx, dy = self:dragCardPos()
  if dx then
    local c = self.dragging
    love.graphics.setColor(0.98, 0.96, 0.9)
    love.graphics.rectangle("fill", dx, dy, CARD_W, CARD_H, 6, 6)
    love.graphics.setColor(0.95, 0.8, 0.2)
    love.graphics.rectangle("line", dx, dy, CARD_W, CARD_H, 6, 6)
    love.graphics.setColor(faceColor(c))
    love.graphics.setFont(self.font_sm)
    love.graphics.print(c:suitString() .. c.number, dx + 6, dy + 5)
    love.graphics.setColor(0, 0, 0)
    love.graphics.setFont(self.font_mid)
    love.graphics.printf(c:zhName(), dx, dy + 46, CARD_W, "center")
  end

  -- 提示条
  love.graphics.setColor(0.15, 0.2, 0.15)
  love.graphics.rectangle("fill", 0, 610, 1130, 40)
  love.graphics.setFont(self.font)
  local req = room.pending
  -- 拖拽中优先显示实时距离/合法性（比 self.msg 更即时）
  local prompt = self:dragStatusText() or self.msg
  -- self.msg 是具体操作反馈（如「距离 2 超出攻击范围 1」），优先级最高，
  -- 不能被下面的默认提示覆盖掉 —— 否则玩家只看到一句无关的套话。
  if (prompt or "") == "" then
    if room.game_over then
      local role_text = room.win_role and (Player.ROLE_ZH[room.win_role] or room.win_role) or ""
      prompt = string.format("对局结束 —— %s阵营获胜（%s）。点击【返回菜单】",
        role_text, room.winner and room.winner.name or "—")
    elseif req and req.player.is_human then
      if req.prompt then
        prompt = req.prompt
      elseif self.picked then
        prompt = "已选中【" .. self.picked:zhName() .. "】，点击一名角色作为目标"
      elseif req.type == "askForUseCard" then
        prompt = "你的出牌阶段：点手牌使用，或【结束出牌】"
      elseif req.type == "askForDiscard" then
        prompt = req.any
          and string.format("制衡：已选 %d 张（可多选，空选 = 不发动，摸等量）",
            self:selectedCount())
          or string.format("弃牌阶段：已选 %d/%d 张", self:selectedCount(), req.n)
      elseif req.type == "askForChooseCard" then
        prompt = "点击展示牌，选择一张收入手中"
      elseif req.type == "askForDiscardFrom" then
        prompt = req.hand_only and "选择弃掉一张手牌（或不弃）"
          or "拆牌：点按钮弃掉对手一张牌（装备/判定区/随机手牌）"
      end
    elseif req then
      if self.driver_state == "thinking" and self.agent then
        prompt = (self.agent:thinkingLabel() or "AI 思考中") .. "…"
      else
        prompt = "等待 " .. req.player.name .. " 响应…"
      end
    end
  end
  love.graphics.setColor(1, 1, 0.85)
  love.graphics.print(prompt, 40, 620)

  -- AI 未配置时给一句明确提示：否则「开着 AI 却打得像 BOT」会让人以为是坏了
  if self.ai_mode ~= "off" and self.ai_error then
    love.graphics.setColor(1, 0.6, 0.5)
    love.graphics.setFont(self.font_sm)
    love.graphics.print("AI 未启用（" .. self.ai_error .. "），这些座位正由规则 BOT 代打", 40, 588)
    love.graphics.setFont(self.font)
  end

  -- 按钮
  love.graphics.setFont(self.font)
  for _, b in ipairs(self.buttons) do
    love.graphics.setColor(0.2, 0.35, 0.2)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(b.text, b.x, b.y + 11, b.w, "center")
  end

  -- AI 推测常驻小面板（右侧空闲区）与详情弹层（模态，最顶层）
  self:drawAIPanel()
  self:drawAIPopup()

  -- 战斗日志：放在左下、手牌上方。
  -- 之前画在 x=620，正好压在自己的仪表盘上，长句还会超出右边缘。
  local LOG_X, LOG_W, LOG_LINE = 12, 440, 16
  local LOG_MAX = 5
  love.graphics.setFont(self.font_sm)
  local n = #room.loglines
  local first = math.max(1, n - LOG_MAX + 1)
  -- 量文字宽度；测试桩的 font 没有 getWidth，量不出来就跳过截断
  local function measure(s)
    if not (self.font_sm and self.font_sm.getWidth) then return nil end
    local ok, w = pcall(self.font_sm.getWidth, self.font_sm, s)
    if not ok or type(w) ~= "number" then return nil end
    return w
  end
  for i = first, n do
    local y = 508 - LOG_LINE * (n - i)
    local text = tostring(room.loglines[i])
    -- 超宽截断（按 UTF-8 字符逐个回退，避免截断出半个字）
    local w = measure(text)
    if w and w > LOG_W then
      local chars, acc = {}, ""
      for ch in text:gmatch("[\33-\127\192-\255][\128-\127]*") do
        table.insert(chars, ch)
      end
      for k = 1, #chars do
        local cand = table.concat(chars, "", 1, k)
        local cw = measure(cand .. "…")
        if cw and cw > LOG_W then break end
        acc = cand
      end
      text = acc .. "…"
    end
    -- 深色底衬 + 浅色文字，压在背景图上也读得清
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", LOG_X - 3, y - 2,
      (measure(text) or 0) + 6, LOG_LINE, 3, 3)
    love.graphics.setColor(0.85, 0.9, 0.82)
    love.graphics.print(text, LOG_X, y)
  end

  -- 必须最后绘制，确保技能说明覆盖牌桌、按钮和日志。
  SkillDesc.draw(self.skillPopup, self.font, self.font_mid, self.font_sm)
end

return RoomScene
