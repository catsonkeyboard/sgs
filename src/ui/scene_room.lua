-- 牌桌场景：人机 1v1 迷你局（杀/闪/桃）
-- 与 headless 测试共用同一个 core/ 引擎——UI 只是协程驱动的另一个响应源。
local class = require "src.class"
local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local AI = require "src.core.ai"
local Card = require "src.core.card"

local RoomScene = class("RoomScene")

local CARD_W, CARD_H = 62, 86

function RoomScene:init(on_exit)
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("你", engine:getGeneral("白板武将"), 1, true)
  local p2 = Player.create("AI·乙", engine:getGeneral("剑阁武将"), 2, false)
  self.human, self.ai_player = p1, p2
  self.room = Room.create(engine, { p1, p2 })
  self.room.drawPile = Standard.buildDrawPile(os.time() % 2147483647)
  self.room:start()
  self.driver = Driver.create(self.room, AI.makeAI())
  self.driver:advance()

  self.on_exit = on_exit
  self.font = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 15)
  self.font_mid = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 20)
  self.msg = ""
  self.buttons = {}
end

-- ===== 布局 =====

function RoomScene:handCardRect(i)
  local x0, y0 = 40, 520
  return x0 + (i - 1) * (CARD_W + 8), y0, CARD_W, CARD_H
end

function RoomScene:cardAt(x, y)
  for i, _ in ipairs(self.human.hand) do
    local cx, cy, cw, ch = self.handCardRect(i)
    if x >= cx and x <= cx + cw and y >= cy and y <= cy + ch then
      return self.human.hand[i], i
    end
  end
  return nil
end

-- ===== 交互 =====

function RoomScene:_refreshButtons()
  local btns = {}
  local req = self.room.pending
  local function step(resp)
    self.room:step(resp)
    self.driver:advance()
  end
  if self.room.game_over then
    table.insert(btns, { text = "返回菜单", cb = function() self.on_exit() end })
  elseif req and req.player.is_human then
    if req.type == "askForUseCard" then
      table.insert(btns, { text = "结束出牌", cb = function() step(nil) end })
    elseif req.type == "askForCard" then
      table.insert(btns, { text = "不出", cb = function() step(nil) end })
    elseif req.type == "askForDiscard" then
      table.insert(btns, {
        text = "自动弃牌",
        cb = function()
          local order = { dodge = 1, slash = 2, peach = 3 }
          local sorted = {}
          for _, c in ipairs(req.player.hand) do table.insert(sorted, c) end
          table.sort(sorted, function(a, b)
            return (order[a.name] or 0) < (order[b.name] or 0)
          end)
          local out = {}
          for i = 1, math.min(req.n, #sorted) do table.insert(out, sorted[i]) end
          step(out)
        end,
      })
    end
  end
  for i, b in ipairs(btns) do
    b.x = 1130 - 40 - i * 120
    b.y = 480
    b.w, b.h = 110, 40
  end
  self.buttons = btns
end

function RoomScene:update(_dt)
  if not self.room.game_over then
    self.driver:advance()
  end
  self:_refreshButtons()
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

  local card = self:cardAt(x, y)
  if not card then return end

  local function step(resp)
    self.room:step(resp)
    self.driver:advance()
  end

  if req.type == "askForUseCard" then
    local p = req.player
    if card.name == "slash" then
      if p.slash_used then self.msg = "本回合已使用过【杀】" return end
      local target = nil
      for _, q in ipairs(self.room.players) do
        if q ~= p and q.alive then target = q break end
      end
      if target then step({ card = card, target = target }) end
    elseif card.name == "peach" then
      if p.hp >= p.max_hp then self.msg = "体力已满，不能用【桃】" return end
      step({ card = card, target = p })
    else
      self.msg = "A0 阶段仅支持主动使用【杀】/【桃】"
    end
  elseif req.type == "askForCard" then
    if card.name == req.card_name then
      step(card)
    else
      self.msg = "请打出【" .. (Card.ZH[req.card_name] or req.card_name) .. "】或点【不出】"
    end
  end
end

-- ===== 渲染 =====

local function drawHp(x, y, hp, max_hp)
  for i = 1, max_hp do
    if i <= hp then
      love.graphics.setColor(0.85, 0.15, 0.1)
    else
      love.graphics.setColor(0.25, 0.25, 0.25)
    end
    love.graphics.circle("fill", x + (i - 1) * 18, y, 7)
  end
end

function RoomScene:draw()
  love.graphics.clear(0.09, 0.13, 0.09)
  local room = self.room

  -- 上方：AI 面板
  love.graphics.setFont(self.font_mid)
  love.graphics.setColor(1, 0.9, 0.7)
  love.graphics.print(self.ai_player.name .. "（" .. self.ai_player.general.name .. "）", 40, 30)
  drawHp(40, 66, self.ai_player.hp, self.ai_player.max_hp)
  love.graphics.setColor(0.7, 0.75, 0.7)
  love.graphics.print("手牌 × " .. #self.ai_player.hand, 240, 32)

  -- 中部：牌堆信息 + 当前回合
  love.graphics.setColor(0.8, 0.85, 0.8)
  love.graphics.setFont(self.font)
  local cur = room.players[room.current_seat]
  love.graphics.print("第 " .. room.turn_count .. " 回合 · 当前行动：" .. (cur and cur.name or "-"), 40, 130)
  love.graphics.print("摸牌堆 " .. #room.drawPile .. " · 弃牌堆 " .. #room.discardPile, 40, 155)

  -- 下方：人类玩家面板 + 手牌
  love.graphics.setFont(self.font_mid)
  love.graphics.setColor(1, 0.9, 0.7)
  love.graphics.print(self.human.name .. "（" .. self.human.general.name .. "）", 40, 478)
  drawHp(40, 455, self.human.hp, self.human.max_hp)

  -- 手牌渲染（显式数字循环：与 ipairs 等价，但对数组异常免疫）
  local hand = self.human.hand
  local count = #hand
  for idx = 1, count do
    local c = hand[idx]
    if c == nil then break end
    local x, y = self.handCardRect(idx)
    love.graphics.setColor(0.96, 0.94, 0.88)
    love.graphics.rectangle("fill", x, y, CARD_W, CARD_H, 6, 6)
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("line", x, y, CARD_W, CARD_H, 6, 6)
    local red = c:isRed()
    love.graphics.setColor(red and 0.8 or 0.1, red and 0.1 or 0.1, red and 0.1 or 0.1)
    love.graphics.print(c:suitString() .. c.number, x + 6, y + 5)
    love.graphics.setFont(self.font_mid)
    love.graphics.print(c:zhName(), x + 14, y + 48)
    love.graphics.setFont(self.font)
  end

  -- 提示条
  love.graphics.setColor(0.15, 0.2, 0.15)
  love.graphics.rectangle("fill", 0, 610, 1130, 40)
  love.graphics.setColor(1, 1, 0.85)
  love.graphics.setFont(self.font)
  local req = room.pending
  local prompt = self.msg
  if room.game_over then
    prompt = room.winner == self.human and "你赢了！点击【返回菜单】再来一局" or "你阵亡了……点击【返回菜单】重整旗鼓"
  elseif req and req.player.is_human then
    if req.prompt then
      prompt = req.prompt
    elseif req.type == "askForUseCard" then
      prompt = "你的出牌阶段：点手牌使用【杀】/【桃】，或【结束出牌】"
    elseif req.type == "askForDiscard" then
      prompt = "弃牌阶段：需弃 " .. req.n .. " 张（点【自动弃牌】）"
    end
  elseif req then
    prompt = "等待 " .. (req.player.name) .. " 响应…"
  end
  love.graphics.print("[A0.1] " .. prompt, 40, 620)

  -- 按钮
  for _, b in ipairs(self.buttons) do
    love.graphics.setColor(0.2, 0.35, 0.2)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(b.text, b.x, b.y + 11, b.w, "center")
  end

  -- 右下日志（最近 12 条，从底往上排）
  love.graphics.setColor(0.65, 0.7, 0.65)
  love.graphics.setFont(self.font)
  local n = #room.loglines
  local start = math.max(1, n - 11)
  for i = start, n do
    love.graphics.print(room.loglines[i], 560, 592 - 18 * (n - i))
  end
end

return RoomScene
