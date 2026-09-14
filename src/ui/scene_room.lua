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
local Bot = require "src.core.bot"
local Skin = require "src.ui.skin"
local Audio = require "src.ui.audio"
local Layout = require "src.ui.layout"
local Effects = require "src.ui.effects"

local RoomScene = class("RoomScene")

local CARD_W, CARD_H = 62, 86
local EQ_W, EQ_H = 50, 26
local JUDGE_S = 20
local PANEL_W, PANEL_H = 210, 104

-- 座位锚点：1=自己（下），2=下家（左），3=对家（上），4=上家（右）
local ANCHORS_4 = {
  [1] = { 40, 440 }, [2] = { 40, 168 }, [3] = { 460, 24 }, [4] = { 880, 168 },
}
local ANCHORS_2 = { [1] = { 40, 440 }, [2] = { 40, 24 } }

function RoomScene:init(on_exit, mode, size)
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

  -- 身份局按 size 建局（8/5/4 人）；武将池循环取，不写死固定四个
  local POOL = { "刘备", "曹操", "孙权", "貂蝉", "吕布", "诸葛亮", "司马懿", "华佗" }

  local players = {}
  if mode == "identity" then
    for i = 1, size do
      local is_human = (i == 1)
      local g = engine:getGeneral(POOL[((i - 1) % #POOL) + 1]) or engine:getGeneral("白板武将")
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

  local seed = os.time() % 2147483647
  self.room = Room.create(engine, players)
  self.room.drawPile = Standard.buildDrawPile(seed)
  self.room.rng = Standard.makeRng(seed)
  if mode == "identity" then
    self.room:setupRoles(Standard.makeRng(seed + 1))
  end
  self.room:start()
  self.driver = Driver.create(self.room, Bot.make())
  self.driver:advance()

  -- 布局：优先按原版 layout.json 的间距参数推导（自适应人数），
  -- 缺少配置时 Layout 内部会退回与原来一致的固定锚点。
  -- 面板尺寸必须传给布局：排版与绘制用同一个宽度，否则右侧会被画布裁掉。
  self.layout = Layout.create(self.skin, #players, PANEL_W, PANEL_H)
  self.anchors = self.layout.anchors
  self.panelW, self.panelH = self.layout:panelSize()
  self.effects = Effects.create()
  self:bindPresentationHooks()

  self.on_exit = on_exit
  self.font = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 15)
  self.font_mid = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 20)
  self.font_sm = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 12)
  self.msg = ""
  self.buttons = {}
  self.selected = {}   -- 弃牌多选
  self.revealed = nil  -- askForChooseCard 候选
  self.picked = nil    -- 已选中、等待指定目标的卡牌
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

function RoomScene:selectedCount()
  local n = 0
  for _, c in ipairs(self.human.hand) do
    if self.selected[c] then n = n + 1 end
  end
  return n
end

function RoomScene:selectedCards()
  local out = {}
  for _, c in ipairs(self.human.hand) do
    if self.selected[c] then table.insert(out, c) end
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
    elseif req.type == "askForDiscardFrom" then
      push("确定拆牌", function()
        local t = req.target
        self:_step((t and t.hand[1]) or nil)
      end)
    elseif req.type == "askForSkillInvoke" then
      -- 主动技征询：玩家自己决定发不发动
      push("发动【" .. tostring(req.skill) .. "】", function() self:_step(true) end)
      push("不发动", function() self:_step(false) end)
    elseif req.type == "askForChoice" then
      -- 【反间】猜花色等：没有选择界面时取第一项，不能把玩家晾在这
      local first = req.choices and req.choices[1]
      push(tostring(first or "确定"), function() self:_step(first) end)
    elseif req.type == "askForGuanxing" then
      -- 【观星】：没有拖拽重排界面时保持原序
      push("保持原序", function() self:_step(nil) end)
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
  self.buttons = btns
end

function RoomScene:update(dt)
  if self.effects and dt then self.effects:update(dt) end
  if not self.room.game_over then
    self.driver:advance()
  end
  self:_refreshButtons()
  local req = self.room.pending
  self.revealed = (req and req.type == "askForChooseCard") and req.cards or nil
  if not (req and req.type == "askForUseCard") then
    self.picked = nil
    self.dragging = nil
  end
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
  self.msg = "" -- 每次点击重新计算提示，避免上一条反馈一直挂着
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
function RoomScene:bindPresentationHooks()
  local room = self.room
  if not room then return end
  local audio, fx = self.audio, self.effects

  room:onEvent("useCard", function(d)
    if d and d.card then
      audio:play(d.card.name)
      if d.from then
        fx:showBanner(string.format("%s 使用【%s】", d.from.name, d.card:zhName()))
      end
    end
  end)

  room:onEvent("damage", function(d)
    if d and d.to then
      audio:play("injure")
      local a = self:anchorOf(d.to)
      if a and fx then
        fx:float(a[1] + (self.panelW or 210) / 2, a[2] + 30, "-" .. tostring(d.n))
      end
    end
  end)

  -- 技能发动：台词（原版 audio/skill/<拼音>1|2.ogg）+ 横幅
  room:onEvent("skill", function(d)
    if not d then return end
    if audio:playSkill(d.skill) and d.player then
      fx:showBanner(string.format("%s 发动【%s】", d.player.name, tostring(d.skill)),
        { 0.95, 0.85, 0.35 })
    end
  end)

  room:onEvent("death", function(d)
    if d and d.player then
      -- 阵亡台词按武将拼音（audio/death/<key>.ogg），取不到再退回通用 death
      if not (d.key and audio:play(d.key)) then audio:play("death") end
      fx:showBanner(string.format("%s 阵亡", d.player.name), { 0.9, 0.3, 0.25 })
    end
  end)
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

-- 武将头像：按 general.key（拼音）在原版 image/generals/avatar 下找
function RoomScene:generalAvatar(p)
  if not (self.skin and p and p.general) then return nil end
  local cache = self.generalImages
  if not cache then return nil end
  local key = p.general.key or p.general.name
  if cache[key] ~= nil then return cache[key] or nil end
  local img = nil
  local rel = self.skin:generalImage(key)
  if rel and love.graphics then
    local path = self.skin:path(rel)
    if path then
      local ok, loaded = pcall(love.graphics.newImage, path)
      if ok then img = loaded end
    end
  end
  cache[key] = img or false
  return img
end

function RoomScene:drawPlayerPanel(p, x, y, highlighted)
  love.graphics.setColor(highlighted and 0.18 or 0.12,
    highlighted and 0.30 or 0.16, highlighted and 0.18 or 0.12)
  love.graphics.rectangle("fill", x, y, PANEL_W, PANEL_H, 8, 8)
  if highlighted then
    love.graphics.setColor(0.95, 0.8, 0.25)
    love.graphics.rectangle("line", x, y, PANEL_W, PANEL_H, 8, 8)
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

  -- 装备
  local slots = { "weapon", "armor", "offensive_horse", "defensive_horse" }
  local idx = 0
  for _, slot in ipairs(slots) do
    local c = p.equips[slot]
    if c then
      local ex = x + 12 + idx * (EQ_W + 4)
      -- 有卡图就画小图标，没有再退回文字框
      local img = cardImage(self, c)
      if img then
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(img, ex, y + 72, 0, EQ_W / img:getWidth(), EQ_H / img:getHeight())
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("line", ex, y + 72, EQ_W, EQ_H, 3, 3)
      else
        love.graphics.setColor(0.85, 0.8, 0.6)
        love.graphics.rectangle("fill", ex, y + 72, EQ_W, EQ_H, 3, 3)
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("line", ex, y + 72, EQ_W, EQ_H, 3, 3)
        love.graphics.printf(c:zhName(), ex, y + 76, EQ_W, "center")
      end
      idx = idx + 1
    end
  end

  -- 判定区
  for i, c in ipairs(p.judges) do
    local jx = x + PANEL_W - 8 - i * (JUDGE_S + 4)
    love.graphics.setColor(0.5, 0.25, 0.15)
    love.graphics.rectangle("fill", jx, y + 72, JUDGE_S, JUDGE_S, 3, 3)
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("line", jx, y + 72, JUDGE_S, JUDGE_S, 3, 3)
  end
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
    love.graphics.setColor(0.96, 0.94, 0.88)
    love.graphics.rectangle("fill", x, y - lifted, CARD_W, CARD_H, 6, 6)
    if self.picked == c then
      love.graphics.setColor(0.95, 0.8, 0.2)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    elseif self.selected[c] then
      love.graphics.setColor(0.95, 0.75, 0.2)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    else
      love.graphics.setColor(0, 0, 0)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    end
    love.graphics.setColor(faceColor(c))
    love.graphics.setFont(self.font_sm)
    love.graphics.print(c:suitString() .. c.number, x + 6, y + 5 - lifted)
    love.graphics.setColor(0, 0, 0)
    love.graphics.setFont(self.font_mid)
    love.graphics.printf(c:zhName(), x, y + 46 - lifted, CARD_W, "center")
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
        prompt = string.format("弃牌阶段：已选 %d/%d 张", self:selectedCount(), req.n)
      elseif req.type == "askForChooseCard" then
        prompt = "点击展示牌，选择一张收入手中"
      elseif req.type == "askForDiscardFrom" then
        prompt = "过河拆桥：点【确定拆牌】弃掉对手一张手牌"
      end
    elseif req then
      prompt = "等待 " .. req.player.name .. " 响应…"
    end
  end
  love.graphics.setColor(1, 1, 0.85)
  love.graphics.print(prompt, 40, 620)

  -- 按钮
  love.graphics.setFont(self.font)
  for _, b in ipairs(self.buttons) do
    love.graphics.setColor(0.2, 0.35, 0.2)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(b.text, b.x, b.y + 11, b.w, "center")
  end

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
end

return RoomScene
