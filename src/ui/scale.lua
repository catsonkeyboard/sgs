-- 统一 UI 缩放：让界面在不同窗口尺寸与高 DPI 屏上都清晰、大小合适。
--
-- 背景：开启 t.window.highdpi 后，坐标单位 = 物理像素（高分屏上窗口的
-- 像素数是逻辑尺寸的 DPI 倍）。若不整体放大 UI，字体与卡牌在 150% 缩放
-- 的屏幕上会小到看不清；若用 love.graphics.scale 整体变换放大，字体是
-- 预光栅化的、会被拉伸发虚（实验测得：变换放大后 86% 覆盖像素为半透明
-- 过渡、255 级灰阶；直接按目标尺寸渲染只有 54%、200 级——明显更锐）。
-- 因此这里的做法是「常量级缩放」：
--   布局常量经 Scale.px() 放大，字体按放大后字号重新光栅化（Scale.font）。
--
-- factor 以设计分辨率 1130x650 为 1.0：默认窗口下与旧版像素级一致；
-- 全屏/最大化时整体放大，窗口缩小时等比缩小（下限 0.75 保可读性）。
local Scale = {}

Scale.factor = 1

local DESIGN_W, DESIGN_H = 1130, 650
local MIN_F, MAX_F = 0.75, 2.6

-- 窗口尺寸或 DPI 变化后调用（love.load / love.resize）
function Scale.refresh()
  if not (love and love.graphics and love.graphics.getDimensions) then return end
  local w, h = love.graphics.getDimensions()
  Scale.factor = math.max(MIN_F,
    math.min(MAX_F, math.min(w / DESIGN_W, h / DESIGN_H)))
end

function Scale.px(n) return n * Scale.factor end

-- 字体工厂：按 factor 放大后光栅化并缓存（同尺寸复用；resize 后新尺寸
-- 自动建新条目）。测试桩的 love.graphics.newFont 可能不存在，判空返回 nil
-- 由调用方兜底。
local cache = {}
function Scale.font(path, size)
  if not (love and love.graphics and love.graphics.newFont) then return nil end
  local px = math.max(9, math.floor(size * Scale.factor + 0.5))
  local key = px .. "|" .. tostring(path)
  local f = cache[key]
  if not f then
    local ok, font = pcall(love.graphics.newFont, path, px)
    f = (ok and font) or nil
    cache[key] = f
  end
  return f
end

return Scale
