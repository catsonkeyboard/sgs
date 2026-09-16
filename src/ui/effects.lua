-- 简易动效：浮动文字 + 出牌横幅
--
-- 说明：原版 skins/defaultSkin.animation.json 在这个皮肤里**是空的**（只有 `}`），
-- 没有可复用的动效定义，因此这里自己实现一套最小够用的：
--   - 受伤时目标面板上浮一个红色 -N
--   - 出牌时在屏幕中部闪一条「谁 使用/发动了 什么」
--   - 阵亡时闪一条提示
-- 全部按时间衰减，纯表现，不参与规则判定，也不阻塞输入。
local class = require "src.class"
local Scale = require "src.ui.scale"
local S = Scale.px

local Effects = class("Effects")

local FLOAT_LIFE = 0.9   -- 浮动文字存活秒数
local BANNER_LIFE = 1.1  -- 横幅存活秒数
local FLASH_LIFE = 0.75  -- 面板闪光存活秒数
local ARROW_LIFE = 0.9   -- 指向箭头存活秒数
local FLY_LIFE = 0.55    -- 飞牌动画时长

function Effects:init()
  self.floats = {}
  self.flashes = {}
  self.arrows = {}
  self.flies = {}
  self.banner = nil
end

function Effects:float(x, y, text, color)
  table.insert(self.floats, {
    x = x, y = y, text = text, life = FLOAT_LIFE,
    color = color or { 0.95, 0.25, 0.2 },
  })
end

-- 某个武将面板上闪一圈（发动技能时用，让玩家看清是谁在发动）
function Effects:flashPanel(x, y, w, h, color)
  table.insert(self.flashes, {
    x = x, y = y, w = w, h = h, life = FLASH_LIFE,
    color = color or { 0.95, 0.85, 0.35 },
  })
end

function Effects:showBanner(text, color)
  self.banner = { text = text, life = BANNER_LIFE, color = color or { 1, 0.95, 0.8 } }
end

-- 指向箭头：技能/卡牌指定目标时，从施法者面板指向目标面板
function Effects:arrow(x1, y1, x2, y2, color)
  table.insert(self.arrows, {
    x1 = x1, y1 = y1, x2 = x2, y2 = y2, life = ARROW_LIFE,
    color = color or { 0.98, 0.85, 0.3 },
  })
end

-- 飞牌动画：打出的牌从源点飞向落点。draw_fn(x, y, w, h, alpha) 由调用方
-- 提供（scene 知道怎么画一张牌），特效层只负责插值轨迹与淡出。
function Effects:fly(draw_fn, x1, y1, x2, y2, w, h)
  table.insert(self.flies, {
    draw = draw_fn, x1 = x1, y1 = y1, x2 = x2, y2 = y2,
    w = w or 62, h = h or 86, life = FLY_LIFE,
  })
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
  for i = #self.flashes, 1, -1 do
    local f = self.flashes[i]
    f.life = f.life - dt
    if f.life <= 0 then table.remove(self.flashes, i) end
  end
  for i = #self.arrows, 1, -1 do
    local a = self.arrows[i]
    a.life = a.life - dt
    if a.life <= 0 then table.remove(self.arrows, i) end
  end
  for i = #self.flies, 1, -1 do
    local f = self.flies[i]
    f.life = f.life - dt
    if f.life <= 0 then table.remove(self.flies, i) end
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

  -- 面板闪光：随剩余时间扩散一圈并淡出
  for _, f in ipairs(self.flashes) do
    local t = math.max(0, math.min(1, f.life / FLASH_LIFE)) -- 1 -> 0
    local grow = (1 - t) * 10                                -- 越淡越外扩
    love.graphics.setColor(f.color[1], f.color[2], f.color[3], t * 0.9)
    if love.graphics.setLineWidth then love.graphics.setLineWidth(3) end
    love.graphics.rectangle("line", f.x - grow, f.y - grow,
      f.w + grow * 2, f.h + grow * 2, 10, 10)
    if love.graphics.setLineWidth then love.graphics.setLineWidth(1) end
  end

  -- 指向箭头：从施法者到目标的连线 + 三角箭头，前半程飞出、后半程淡出
  for _, a in ipairs(self.arrows) do
    local t = math.max(0, math.min(1, a.life / ARROW_LIFE)) -- 1 -> 0
    local alpha = t < 0.5 and 1 or (t - 0.5) * 2            -- 后半程才淡出
    if love.graphics.line and love.graphics.polygon then
      love.graphics.setColor(a.color[1], a.color[2], a.color[3], alpha * 0.85)
      if love.graphics.setLineWidth then love.graphics.setLineWidth(3) end
      love.graphics.line(a.x1, a.y1, a.x2, a.y2)
      if love.graphics.setLineWidth then love.graphics.setLineWidth(1) end
      -- 箭头：沿方向画一个小三角
      local dx, dy = a.x2 - a.x1, a.y2 - a.y1
      local len = math.sqrt(dx * dx + dy * dy)
      if len > 1 then
        local ux, uy = dx / len, dy / len -- 单位方向
        local px, py = -uy, ux            -- 单位法向
        local tip, back, side = 14, 12, 6
        love.graphics.polygon("fill",
          a.x2, a.y2,
          a.x2 - ux * back + px * side, a.y2 - uy * back + py * side,
          a.x2 - ux * back - px * side, a.y2 - uy * back - py * side)
        love.graphics.circle("fill", a.x2 - ux * tip, a.y2 - uy * tip, 3)
      end
    end
  end

  -- 飞牌：前半段易入（快出），后半段缓停；终点处短暂停留再消失
  for _, f in ipairs(self.flies) do
    local p = 1 - math.max(0, math.min(1, f.life / FLY_LIFE)) -- 0 -> 1
    local ease = 1 - (1 - p) * (1 - p)                         -- ease-out
    local x = f.x1 + (f.x2 - f.x1) * ease
    local y = f.y1 + (f.y2 - f.y1) * ease
    local alpha = p > 0.85 and (1 - p) / 0.15 or 1
    if f.draw then f.draw(x - f.w / 2, y - f.h / 2, f.w, f.h, alpha) end
  end

  -- 中部横幅
  if self.banner then
    local a = math.max(0, math.min(1, self.banner.life / BANNER_LIFE))
    local w, h = S(320), S(34)
    local x, y = (sceneW - w) / 2, sceneH * 0.32
    love.graphics.setColor(0, 0, 0, a * 0.45)
    love.graphics.rectangle("fill", x, y, w, h, 8, 8)
    love.graphics.setColor(self.banner.color[1], self.banner.color[2],
      self.banner.color[3], a)
    love.graphics.rectangle("line", x, y, w, h, 8, 8)
    if font then love.graphics.setFont(font) end
    love.graphics.printf(self.banner.text, x, y + S(8), w, "center")
  end

  love.graphics.setColor(1, 1, 1, 1)
end

return Effects
