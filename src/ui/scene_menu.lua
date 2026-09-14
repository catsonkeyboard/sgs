-- 主菜单场景：标题 + 模式选择
local class = require "src.class"

local MenuScene = class("MenuScene")

function MenuScene:init(on_start)
  self.on_start = on_start
  self.font_big = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 56)
  self.font = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 18)
  self.font_sm = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 13)
  self.buttons = {
    { x = 300, y = 370, w = 250, h = 60, text = "身份局（4 人）", mode = "identity",
      desc = "主公 / 忠臣 / 反贼 / 内奸" },
    { x = 580, y = 370, w = 250, h = 60, text = "1v1 死斗", mode = "duel",
      desc = "标准牌堆，两人对决" },
  }
end

function MenuScene:draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.10, 0.16, 0.10)

  love.graphics.setColor(1, 0.95, 0.8)
  love.graphics.setFont(self.font_big)
  love.graphics.printf("三 国 杀", 0, h * 0.18, w, "center")

  love.graphics.setFont(self.font)
  love.graphics.setColor(0.75, 0.8, 0.75)
  love.graphics.printf("sgs-love · A1 · 标准牌堆（锦囊 / 装备 / 判定 / 身份）",
    0, h * 0.18 + 84, w, "center")

  for _, b in ipairs(self.buttons) do
    love.graphics.setColor(0.75, 0.2, 0.15)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 10, 10)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(self.font)
    love.graphics.printf(b.text, b.x, b.y + 18, b.w, "center")
    love.graphics.setColor(0.7, 0.72, 0.7)
    love.graphics.setFont(self.font_sm)
    love.graphics.printf(b.desc, b.x, b.y + b.h + 10, b.w, "center")
  end

  love.graphics.setColor(0.5, 0.55, 0.5)
  love.graphics.setFont(self.font_sm)
  love.graphics.printf("LÖVE 11.5 · 从 QSanguosha (C++/Qt) 迁移", 0, h - 40, w, "center")
end

function MenuScene:mousepressed(x, y, button)
  if button ~= 1 then return end
  for _, b in ipairs(self.buttons) do
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      self.on_start(b.mode)
      return
    end
  end
end

return MenuScene
