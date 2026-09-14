-- 主菜单场景：标题 + 开始按钮
local class = require "src.class"

local MenuScene = class("MenuScene")

function MenuScene:init(on_start)
  self.on_start = on_start
  self.font_big = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 56)
  self.font = love.graphics.newFont("assets/font/DroidSansFallback.ttf", 18)
  self.btn = { x = 465, y = 400, w = 200, h = 56, text = "开始游戏" }
end

function MenuScene:draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.10, 0.16, 0.10)

  love.graphics.setColor(1, 0.95, 0.8)
  love.graphics.setFont(self.font_big)
  love.graphics.printf("三 国 杀", 0, h * 0.22, w, "center")

  love.graphics.setFont(self.font)
  love.graphics.setColor(0.75, 0.8, 0.75)
  love.graphics.printf("sgs-love · A1 人机 1v1 · 标准牌堆（锦囊/装备/判定）", 0, h * 0.22 + 90, w, "center")

  local b = self.btn
  love.graphics.setColor(0.75, 0.2, 0.15)
  love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 10, 10)
  love.graphics.setColor(1, 1, 1)
  love.graphics.printf(b.text, b.x, b.y + 16, b.w, "center")

  love.graphics.setColor(0.5, 0.55, 0.5)
  love.graphics.printf("LÖVE 11.5 · 从 QSanguosha (C++/Qt) 迁移", 0, h - 40, w, "center")
end

function MenuScene:mousepressed(x, y, button)
  if button ~= 1 then return end
  local b = self.btn
  if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
    self.on_start()
  end
end

return MenuScene
