-- 联机牌桌：不本地跑引擎，只渲染服务端下发的快照并应答请求。
--
-- 与 scene_room 的分工：
--   scene_room = 本地单机（自己持有权威 Room + Driver）
--   scene_net  = 联机客户端（权威在服务端，这里只负责显示与应答）
-- 刻意做成独立文件而不是给 scene_room 打补丁：那个文件已近 900 行，
-- 混进去会让两条路径互相拖累。
local class = require "src.class"
local Layout = require "src.ui.layout"
local Skin = require "src.ui.skin"
local Effects = require "src.ui.effects"
local Audio = require "src.ui.audio"

local CARD_W, CARD_H = 92, 128

local NetScene = class("NetScene")

function NetScene:init(on_exit, client, name)
  self.on_exit = on_exit
  self.client = client
  self.name = name or "我"

  self.skin = Skin.create()
  self.effects = Effects.create()
  self.audio = Audio.create(self.skin)
  self.layout = Layout.create(self.skin, 5, 210, 96)
  self.panelW, self.panelH = self.layout:panelSize()

  self.font = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 18)
  self.font_sm = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 13)
  self.font_mid = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 15)

  self.snap = nil      -- 服务端快照
  self.hand = {}       -- 本人手牌（slim 表）
  self.req = nil       -- 待应答请求
  self.logs = {}
  self.msg = ""
  self.seat = nil
  self.picked = nil
  self.buttons = {}

  client:hello()
  client:ready(true)
  client:flush()
end

-- 取一条消息并处理
function NetScene:poll()
  local c = self.client
  c:flush()
  if c.seat and not self.seat then self.seat = c.seat end
  if c.state then self.snap = c.state end
  if c.over and not self.overShown then
    self.overShown = true
    self.effects:showBanner(self:overText(c.over), { 0.95, 0.85, 0.35 })
  end
  -- 请求变化时刷新手牌与提示
  local cur = nil
  for _, r in pairs(c.requests) do cur = r break end
  if cur ~= self.req then
    self.req = cur
    if cur then
      self.hand = cur.hand or self.hand
      self.picked = nil
      self.msg = self:promptOf(cur)
    end
  end
  if c.over then self.msg = self:overText(c.over) end
end

function NetScene:promptOf(r)
  if r.req == "askForUseCard" then
    return "你的回合：点手牌选中，再点目标角色（或点【结束出牌】）"
  elseif r.req == "askForCard" then
    return string.format("需要打出【%s】，或点【不出】", r.card_name or "?")
  elseif r.req == "askForSkillInvoke" then
    return string.format("是否发动【%s】？", r.skill or "?")
  elseif r.req == "askForDiscard" then
    return string.format("请选择 %d 张牌弃置", r.n or 1)
  end
  return "等待你的操作"
end

function NetScene:overText(o)
  local w = o and o.winner
  return w and ("对局结束，胜者：" .. tostring(w)) or "对局结束"
end

function NetScene:update(dt)
  self:poll()
  self.effects:update(dt)
  self:_refreshButtons()
end

function NetScene:_refreshButtons()
  local btns = {}
  local function push(text, cb) table.insert(btns, { text = text, cb = cb }) end
  local y, h = 610, 40
  local x = 700
  if self.client.over then
    push("返回菜单", function() self.on_exit() end)
  elseif self.req then
    if self.req.req == "askForUseCard" then
      push("结束出牌", function() self:_respond(nil) end)
      if self.picked then push("取消选择", function() self.picked = nil end) end
    elseif self.req.req == "askForCard" then
      push("不出", function() self:_respond(nil) end)
    elseif self.req.req == "askForSkillInvoke" then
      push("发动", function() self:_respond(true) end)
      push("不发动", function() self:_respond(false) end)
    end
  end
  for i, b in ipairs(btns) do
    b.x, b.y, b.w, b.h = x + (i - 1) * 130, y, 120, h
  end
  self.buttons = btns
end

function NetScene:_respond(value, card_id, target_seat)
  local r = self.req
  if not r then return end
  self.client:respond(r.id, value)
  if card_id or target_seat then
    self.client.channel:send {
      type = "resp", id = r.id, value = value,
      card_id = card_id, target_seat = target_seat,
    }
  end
  self.req = nil
  self.picked = nil
  self.client.requests[r.id] = nil
end

-- ===== 输入 =====

function NetScene:handCardRect(i)
  return 40 + (i - 1) * (CARD_W + 8), 470, CARD_W, CARD_H
end

function NetScene:cardAt(x, y)
  for i, c in ipairs(self.hand) do
    local cx, cy = self:handCardRect(i)
    if x >= cx and x <= cx + CARD_W and y >= cy and y <= cy + CARD_H then
      return c, i
    end
  end
  return nil
end

function NetScene:panelAt(x, y)
  for i, p in ipairs(self.snap and self.snap.players or {}) do
    local a = self.layout.anchors[i]
    if a and x >= a[1] and x <= a[1] + self.panelW
      and y >= a[2] and y <= a[2] + self.panelH then
      return p, i
    end
  end
  return nil
end

function NetScene:mousepressed(x, y, button)
  if button ~= 1 then return end
  for _, b in ipairs(self.buttons) do
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      b.cb()
      return
    end
  end
  if not self.req then return end
  if self.req.req ~= "askForUseCard" then return end

  -- 已选中 → 点角色指定目标
  if self.picked then
    local p, seat = self:panelAt(x, y)
    if p then
      if seat == self.seat then
        self.msg = "这张牌不能指定自己"
      else
        self:_respond(nil, self.picked.id, seat)
      end
    else
      self.picked = nil
    end
    return
  end
  local c = self:cardAt(x, y)
  if c then
    self.picked = c
    self.msg = "已选中【" .. (c.zh or c.name) .. "】，点目标角色"
  end
end

-- ===== 绘制 =====

function NetScene:draw()
  love.graphics.clear(0.09, 0.13, 0.09)

  -- 玩家面板（来自服务端快照）
  if self.snap then
    for i, p in ipairs(self.snap.players or {}) do
      local a = self.layout.anchors[i]
      if a then self:drawPanel(p, a[1], a[2], i == self.seat) end
    end
  else
    love.graphics.setColor(0.7, 0.75, 0.7)
    love.graphics.setFont(self.font)
    love.graphics.printf("正在连接服务端…", 0, 280, 1130, "center")
  end

  -- 手牌
  for i, c in ipairs(self.hand) do
    local x, y = self:handCardRect(i)
    local lifted = (self.picked == c) and 14 or 0
    love.graphics.setColor(0.96, 0.94, 0.88)
    love.graphics.rectangle("fill", x, y - lifted, CARD_W, CARD_H, 6, 6)
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("line", x, y - lifted, CARD_W, CARD_H, 6, 6)
    love.graphics.setFont(self.font_mid)
    love.graphics.printf(c.zh or c.name or "?", x, y + 46 - lifted, CARD_W, "center")
    love.graphics.setFont(self.font_sm)
    love.graphics.print(tostring(c.number or ""), x + 6, y + 5 - lifted)
  end

  -- 按钮
  for _, b in ipairs(self.buttons) do
    love.graphics.setColor(0.25, 0.35, 0.25)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(self.font)
    love.graphics.printf(b.text, b.x, b.y + 10, b.w, "center")
  end

  -- 日志（右下角最近 6 条）
  love.graphics.setFont(self.font_sm)
  love.graphics.setColor(0.75, 0.8, 0.75)
  local logs = self.client.logs or {}
  local from = math.max(1, #logs - 5)
  for i = from, #logs do
    love.graphics.print(logs[i], 700, 470 + (i - from) * 18)
  end

  -- 提示条
  love.graphics.setColor(0.15, 0.2, 0.15)
  love.graphics.rectangle("fill", 0, 560, 700, 40)
  love.graphics.setColor(1, 0.95, 0.85)
  love.graphics.setFont(self.font)
  love.graphics.print(self.msg or "", 16, 570)

  -- 动效
  local w, h = love.graphics.getDimensions()
  self.effects:draw(w, h, self.font, self.font_mid)
end

function NetScene:drawPanel(p, x, y, isSelf)
  love.graphics.setColor(isSelf and 0.18 or 0.12, 0.2, isSelf and 0.22 or 0.16)
  love.graphics.rectangle("fill", x, y, self.panelW, self.panelH, 8, 8)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setFont(self.font_sm)
  love.graphics.print(string.format("%s%s", p.name or "?",
    isSelf and "（你）" or ""), x + 8, y + 6)
  if p.alive == false then
    love.graphics.setColor(0.9, 0.35, 0.3)
    love.graphics.print("已阵亡", x + 8, y + 26)
  else
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(string.format("体力 %s/%s · 手牌 %s",
      tostring(p.hp), tostring(p.max_hp), tostring(p.hand)), x + 8, y + 26)
  end
  if p.general then
    love.graphics.setColor(0.85, 0.9, 0.85)
    love.graphics.print(tostring(p.general), x + 8, y + 46)
  end
  if p.role then
    love.graphics.setColor(0.95, 0.85, 0.4)
    love.graphics.print(tostring(p.role), x + 8, y + 64)
  end
end

return NetScene
