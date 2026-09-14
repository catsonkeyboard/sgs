-- 简易动效：浮动文字 + 出牌横幅
--
-- 说明：原版 skins/defaultSkin.animation.json 在这个皮肤里**是空的**（只有 `}`），
-- 没有可复用的动效定义，因此这里自己实现一套最小够用的：
--   - 受伤时目标面板上浮一个红色 -N
--   - 出牌时在屏幕中部闪一条「谁 使用/发动了 什么」
--   - 阵亡时闪一条提示
-- 全部按时间衰减，纯表现，不参与规则判定，也不阻塞输入。
local class = require "src.class"

local Effects = class("Effects")

local FLOAT_LIFE = 0.9   -- 浮动文字存活秒数
local BANNER_LIFE = 1.1  -- 横幅存活秒数

function Effects:init()
  self.floats = {}
  self.banner = nil
end

function Effects:float(x, y, text, color)
  table.insert(self.floats, {
    x = x, y = y, text = text, life = FLOAT_LIFE,
    color = color or { 0.95, 0.25, 0.2 },
  })
end

function Effects:showBanner(text, color)
  self.banner = { text = text, life = BANNER_LIFE, color = color or { 1, 0.95, 0.8 } }
end

function Effects:update(dt)
  for i = #self.floats, 1, -1 do
    local f = self.floats[i]
    f.life = f.life - dt
    f.y = f.y - 28 * dt -- 向上飘
    if f.life <= 0 then table.remove(self.floats, i) end
  end
  if self.banner then
    self.banner.life = self.banner.life - dt
    if self.banner.life <= 0 then self.banner = nil end
  end
end

function Effects:draw(sceneW, sceneH, font, font_lg)
  -- 浮动文字
  for _, f in ipairs(self.floats) do
    local a = math.max(0, math.min(1, f.life / FLOAT_LIFE))
    love.graphics.setColor(f.color[1], f.color[2], f.color[3], a)
    if font_lg then love.graphics.setFont(font_lg) end
    love.graphics.printf(f.text, f.x - 60, f.y, 120, "center")
  end

  -- 中部横幅
  if self.banner then
    local a = math.max(0, math.min(1, self.banner.life / BANNER_LIFE))
    local w, h = 320, 34
    local x, y = (sceneW - w) / 2, sceneH * 0.32
    love.graphics.setColor(0, 0, 0, a * 0.45)
    love.graphics.rectangle("fill", x, y, w, h, 8, 8)
    love.graphics.setColor(self.banner.color[1], self.banner.color[2],
      self.banner.color[3], a)
    love.graphics.rectangle("line", x, y, w, h, 8, 8)
    if font then love.graphics.setFont(font) end
    love.graphics.printf(self.banner.text, x, y + 8, w, "center")
  end

  love.graphics.setColor(1, 1, 1, 1)
end

return Effects
