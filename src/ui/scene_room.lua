-- 牌桌场景：人机 1v1（标准牌堆 + 锦囊/装备/判定）
-- 与 headless 测试共用同一个 core/ 引擎——UI 只是协程驱动的另一个响应源。
-- 注意：core/ 里的同一份规则对 UI 与 AI 生效，UI 不实现任何规则判断，
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

local RoomScene = class("RoomScene")

local CARD_W, CARD_H = 62, 86
local EQ_W, EQ_H = 54, 30
local JUDGE_S = 22

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
  self.font_sm = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 12)
  self.msg = ""
  self.buttons = {}
  self.selected = {}   -- 弃牌阶段多选：[card]=true
  self.revealed = nil  -- askForChooseCard 的候选牌
end

-- ===== 布局 =====

function RoomScene:handCardRect(i)
  local x0, y0 = 40, 520
  return x0 + (i - 1) * (CARD_W + 8), y0, CARD_W, CARD_H
end

function RoomScene:cardAt(x, y)
  local hand = self.human.hand
  local count = #hand
  for idx = 1, count do
    local cx, cy, cw, ch = self:handCardRect(idx)
    if x >= cx and x <= cx + cw and y >= cy and y <= cy + ch then
      return hand[idx], idx
    end
  end
  return nil
end

-- 便利：选中的弃牌数量
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

-- 人类玩家的对手列表（1v1 下只有一个）
function RoomScene:opponents()
  local out = {}
  for _, q in ipairs(self.room.players) do
    if q ~= self.human and q.alive then table.insert(out, q) end
  end
  return out
end

-- ===== 交互 =====

function RoomScene:_step(resp)
  self.selected = {}
  self.revealed = nil
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
    elseif req.type == "askForCard" then
      push("不出", function() self:_step(nil) end)
    elseif req.type == "askForDiscard" then
      local need = req.n
      local have = self:selectedCount()
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
      -- 对手手牌不可见，随机取一张（与原版一致的默认行为）
      push("确定拆牌", function()
        local t = req.target
        self:_step((t and t.hand[1]) or nil)
      end)
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
  local req = self.room.pending
  self.revealed = (req and req.type == "askForChooseCard") and req.cards or nil
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

  -- 五谷丰登：从展示的牌里挑一张
  if req.type == "askForChooseCard" and self.revealed then
    for i, c in ipairs(self.revealed) do
      local cx = 40 + (i - 1) * (CARD_W + 8)
      if x >= cx and x <= cx + CARD_W and y >= 300 and y <= 300 + CARD_H then
        self:_step(c)
        return
      end
    end
    return
  end

  local card = self:cardAt(x, y)
  if not card then return end

  if req.type == "askForUseCard" then
    local def = Cards.get(card.name)
    if not def then self.msg = "这张牌暂无规则" return end
    local target = self.human
    if def.target == "enemy" then
      local foes = self:opponents()
      target = foes[1]
      if not target then self.msg = "没有合法目标" return end
    end
    self.msg = ""
    self:_step({ card = card, target = target })

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
    if i <= hp then
      love.graphics.setColor(0.85, 0.15, 0.1)
    else
      love.graphics.setColor(0.25, 0.25, 0.25)
    end
    love.graphics.circle("fill", x + (i - 1) * 18, y, 7)
  end
end

local function cardFaceColor(c)
  if not c then return 0.5, 0.5, 0.5 end
  local red = c:isRed()
  return red and 0.8 or 0.1, red and 0.1 or 0.1, red and 0.1 or 0.1
end

-- 画一张牌（正面）
local function drawCard(x, y, w, h, c, font, font_sm)
  love.graphics.setColor(0.96, 0.94, 0.88)
  love.graphics.rectangle("fill", x, y, w, h, 6, 6)
  love.graphics.setColor(0, 0, 0)
  love.graphics.rectangle("line", x, y, w, h, 6, 6)
  love.graphics.setColor(cardFaceColor(c))
  love.graphics.setFont(font_sm)
  love.graphics.print(c:suitString() .. c.number, x + 5, y + 4)
  love.graphics.setColor(0, 0, 0)
  love.graphics.setFont(font)
  love.graphics.printf(c:zhName(), x, y + h / 2 - 10, w, "center")
end

-- 画背面（对手手牌）
local function drawCardBack(x, y, w, h)
  love.graphics.setColor(0.3, 0.35, 0.45)
  love.graphics.rectangle("fill", x, y, w, h, 6, 6)
  love.graphics.setColor(0.15, 0.18, 0.24)
  love.graphics.rectangle("line", x, y, w, h, 6, 6)
end

local function drawEquips(p, x, y, font_sm)
  local slots = { { "weapon", "武" }, { "armor", "防" },
    { "offensive_horse", "攻马" }, { "defensive_horse", "防马" } }
  local idx = 0
  for _, item in ipairs(slots) do
    local c = p.equips[item[1]]
    if c then
      local ex = x + idx * (EQ_W + 6)
      love.graphics.setColor(0.85, 0.8, 0.6)
      love.graphics.rectangle("fill", ex, y, EQ_W, EQ_H, 4, 4)
      love.graphics.setColor(0, 0, 0)
      love.graphics.rectangle("line", ex, y, EQ_W, EQ_H, 4, 4)
      love.graphics.setFont(font_sm)
      love.graphics.printf(c:zhName(), ex, y + 8, EQ_W, "center")
      idx = idx + 1
    end
  end
  return idx
end

local function drawJudges(p, x, y, font_sm)
  love.graphics.setFont(font_sm)
  for i, c in ipairs(p.judges) do
    local jx = x + (i - 1) * (JUDGE_S + 6)
    love.graphics.setColor(0.5, 0.25, 0.15)
    love.graphics.rectangle("fill", jx, y, JUDGE_S, JUDGE_S, 3, 3)
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("line", jx, y, JUDGE_S, JUDGE_S, 3, 3)
  end
end

function RoomScene:draw()
  love.graphics.clear(0.09, 0.13, 0.09)
  local room = self.room

  -- 上方：AI 面板
  love.graphics.setFont(self.font_mid)
  love.graphics.setColor(1, 0.9, 0.7)
  love.graphics.print(self.ai_player.name .. "（" .. self.ai_player.general.name .. "）", 40, 26)
  drawHp(40, 60, self.ai_player.hp, self.ai_player.max_hp)
  love.graphics.setColor(0.7, 0.75, 0.7)
  love.graphics.print("手牌 × " .. #self.ai_player.hand, 240, 28)
  drawEquips(self.ai_player, 240, 48, self.font_sm)
  drawJudges(self.ai_player, 40, 82, self.font_sm)

  -- 中部：回合 / 牌堆
  love.graphics.setColor(0.8, 0.85, 0.8)
  love.graphics.setFont(self.font)
  local cur = room.players[room.current_seat]
  local phase = self.human.phase or "-"
  love.graphics.print(string.format("第 %d 回合 · 行动：%s · 阶段：%s",
    room.turn_count, cur and cur.name or "-", phase), 40, 130)
  love.graphics.print(string.format("摸牌堆 %d · 弃牌堆 %d",
    #room.drawPile, #room.discardPile), 40, 155)

  -- 五谷丰登展示区
  if self.revealed and #self.revealed > 0 then
    love.graphics.setColor(0.9, 0.85, 0.6)
    love.graphics.print("五谷丰登：点击一张收入手中", 40, 278)
    for i, c in ipairs(self.revealed) do
      drawCard(40 + (i - 1) * (CARD_W + 8), 300, CARD_W, CARD_H, c, self.font, self.font_sm)
    end
  end

  -- 下方：人类玩家
  love.graphics.setFont(self.font_mid)
  love.graphics.setColor(1, 0.9, 0.7)
  love.graphics.print(self.human.name .. "（" .. self.human.general.name .. "）", 40, 448)
  drawHp(40, 470, self.human.hp, self.human.max_hp)
  drawEquips(self.human, 240, 452, self.font_sm)
  drawJudges(self.human, 40, 488, self.font_sm)

  -- 手牌
  love.graphics.setFont(self.font)
  for idx = 1, #self.human.hand do
    local c = self.human.hand[idx]
    if c == nil then break end
    local x, y = self:handCardRect(idx)
    local lifted = self.selected[c] and 14 or 0
    love.graphics.setColor(0.96, 0.94, 0.88)
    love.graphics.rectangle("fill", x, y - lifted, CARD_W, CARD_H, 6, 6)
    if self.selected[c] then
      love.graphics.setColor(0.95, 0.75, 0.2)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    else
      love.graphics.setColor(0, 0, 0)
      love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    end
    love.graphics.setColor(cardFaceColor(c))
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
    prompt = room.winner == self.human and "你赢了！点击【返回菜单】再来一局"
      or "你阵亡了……点击【返回菜单】重整旗鼓"
  elseif req and req.player.is_human then
    if req.prompt then
      prompt = req.prompt
    elseif req.type == "askForUseCard" then
      prompt = "你的出牌阶段：点手牌使用，或【结束出牌】"
    elseif req.type == "askForDiscard" then
      prompt = string.format("弃牌阶段：已选 %d/%d 张", self:selectedCount(), req.n)
    elseif req.type == "askForChooseCard" then
      prompt = "点击上方展示牌，选择一张收入手中"
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
    love.graphics.print(room.loglines[i], 560, 592 - 16 * (n - i))
  end
end

return RoomScene
