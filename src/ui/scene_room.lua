-- 牌桌场景：身份局（4 人）与 1v1 死斗
-- 与 headless 测试共用同一个 core/ 引擎——UI 只是协程驱动的另一个响应源。
-- core/ 里的同一份规则对 UI 与 AI 生效；UI 不实现任何规则判断，
-- 只把人类玩家的鼠标点击翻译成 room:step(response)。
local class = require "src.class"
local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Cards = require "src.core.cards"
local Card = require "src.core.card"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local AI = require "src.core.ai"
local Skin = require "src.ui.skin"
local Audio = require "src.ui.audio"

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

function RoomScene:init(on_exit, mode)
  -- 皮肤配置（原版 skins/*.json）与音频。缺资源时全部安全降级，不影响对局。
  self.skin = Skin.create()
  self.cardImages = {}
  self.audio = Audio.create(self.skin)
  local engine = Engine.create()
  Standard.setup(engine)
  -- 加载 diy/ 下的原版扩展脚本；单个脚本出错不应拖垮整局，故吞掉异常
  pcall(function()
    require("src.compat.loader").loadDirectory(engine, "diy")
  end)
  mode = mode or "identity"

  local players = {}
  if mode == "identity" then
    local generals = { "张飞", "曹操", "司马懿", "华佗" }
    for i = 1, 4 do
      local is_human = (i == 1)
      local g = engine:getGeneral(generals[i]) or engine:getGeneral("白板武将")
      table.insert(players,
        Player.create(is_human and "你" or ("AI·" .. g.name), g, i, is_human))
    end
  else
    table.insert(players, Player.create("你", engine:getGeneral("白板武将"), 1, true))
    table.insert(players, Player.create("AI·乙", engine:getGeneral("剑阁武将"), 2, false))
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
  self.driver = Driver.create(self.room, AI.makeAI())
  self.driver:advance()

  self.anchors = (#players == 2) and ANCHORS_2 or ANCHORS_4
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

function RoomScene:anchorOf(p)
  local a = self.anchors[p.seat] or { 40, 24 }
  return a[1], a[2]
end

function RoomScene:panelAt(x, y)
  for _, p in ipairs(self.players) do
    local px, py = self:anchorOf(p)
    if x >= px and x <= px + PANEL_W and y >= py and y <= py + PANEL_H then
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
    return p ~= self.human
  end
  return p == self.human
end

-- ===== 交互 =====

function RoomScene:_step(resp)
  self.selected = {}
  self.revealed = nil
  self.picked = nil
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
    end
  end

  for i, b in ipairs(btns) do
    b.x = 1130 - 40 - i * 120
    b.y = 300
    b.w, b.h = 110, 40
  end
  self.buttons = btns
end

function RoomScene:update(_dt)
  if not self.room.game_over then
    self.driver:advance()
  end
  self:_refreshButtons()
  local req = self.room.pending
  self.revealed = (req and req.type == "askForChooseCard") and req.cards or nil
  if not (req and req.type == "askForUseCard") then self.picked = nil end
end

function RoomScene:_useOn(card, target)
  self.msg = ""
  self:_step({ card = card, target = target })
end

function RoomScene:mousepressed(x, y, button)
  if button ~= 1 then return end
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

  -- 已选中卡牌 → 点击玩家面板指定目标
  if self.picked then
    local p = self:panelAt(x, y)
    if p and self:isValidTarget(p) then
      self:_useOn(self.picked, p)
    elseif p then
      self.msg = "该目标不合法"
    else
      self.picked = nil
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
      local foes = 0
      for _, q in ipairs(self.players) do
        if q ~= self.human and q.alive then foes = foes + 1 end
      end
      if foes == 0 then self.msg = "没有合法目标" return end
      self.picked = card
      self.msg = "已选中【" .. card:zhName() .. "】，点击目标角色"
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

local function drawHp(x, y, hp, max_hp)
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

function RoomScene:drawPlayerPanel(p, x, y, highlighted)
  love.graphics.setColor(highlighted and 0.18 or 0.12,
    highlighted and 0.30 or 0.16, highlighted and 0.18 or 0.12)
  love.graphics.rectangle("fill", x, y, PANEL_W, PANEL_H, 8, 8)
  if highlighted then
    love.graphics.setColor(0.95, 0.8, 0.25)
    love.graphics.rectangle("line", x, y, PANEL_W, PANEL_H, 8, 8)
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

  drawHp(x + 12, y + 38, p.hp, p.max_hp)

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
      love.graphics.setColor(0.85, 0.8, 0.6)
      love.graphics.rectangle("fill", ex, y + 72, EQ_W, EQ_H, 3, 3)
      love.graphics.setColor(0, 0, 0)
      love.graphics.rectangle("line", ex, y + 72, EQ_W, EQ_H, 3, 3)
      love.graphics.printf(c:zhName(), ex, y + 76, EQ_W, "center")
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

function RoomScene:draw()
  love.graphics.clear(0.09, 0.13, 0.09)
  local room = self.room

  for _, p in ipairs(self.players) do
    local x, y = self:anchorOf(p)
    local hl = (self.picked ~= nil) and self:isValidTarget(p) and (p ~= self.human)
    self:drawPlayerPanel(p, x, y, hl)
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

  -- 提示条
  love.graphics.setColor(0.15, 0.2, 0.15)
  love.graphics.rectangle("fill", 0, 610, 1130, 40)
  love.graphics.setFont(self.font)
  local req = room.pending
  local prompt = self.msg
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

  -- 日志
  love.graphics.setColor(0.65, 0.7, 0.65)
  love.graphics.setFont(self.font_sm)
  local n = #room.loglines
  local start = math.max(1, n - 11)
  for i = start, n do
    love.graphics.print(room.loglines[i], 620, 592 - 16 * (n - i))
  end
end

return RoomScene
