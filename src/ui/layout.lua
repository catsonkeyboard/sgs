-- 牌桌布局：按原版 skins/defaultSkin.layout.json 的参数推导座位坐标
--
-- 原版不给绝对座位坐标，只给「内边距 / 间距 / 各区域尺寸」，位置是算出来的。
-- 这里复刻了这个思路：
--   自己（dashboard）固定在底部居中；
--   其余玩家沿上/左/右三边分布，按 photoHDistance / photoVDistance 排开。
--
-- 拿不到配置（无原版资源）时全部退回内置默认值，布局与改造前一致。
local class = require "src.class"

local Layout = class("Layout")

local DEFAULTS = {
  sceneW = 1130, sceneH = 650,
  photoW = 210, photoH = 104,
  roomPadding = 10,
  dashboardPadding = 40,
  hDistance = 32,
  vDistance = 32,
  dashboardY = 440,
  bottomBarH = 40,
}

function Layout:init(skin, n)
  self.skin = skin
  self.n = n or 4
  local sk = skin
  self.sceneW = (sk and sk:number("room.minimumSceneSize[0]", 0))
  if not self.sceneW or self.sceneW <= 0 then self.sceneW = DEFAULTS.sceneW end
  self.sceneH = DEFAULTS.sceneH

  self.photoW = (sk and sk:number("photo.normalWidth")) or DEFAULTS.photoW
  self.photoH = (sk and sk:number("photo.normalHeight")) or DEFAULTS.photoH
  self.roomPadding = (sk and sk:number("room.photoRoomPadding")) or DEFAULTS.roomPadding
  self.dashPadding = (sk and sk:number("room.photoDashboardPadding")) or DEFAULTS.dashboardPadding
  self.hDist = (sk and sk:number("room.photoHDistance")) or DEFAULTS.hDistance
  self.vDist = (sk and sk:number("room.photoVDistance")) or DEFAULTS.vDistance
  self.bottomBarH = DEFAULTS.bottomBarH

  -- photo 尺寸原本是 157x181（含头像），我们的面板更窄，按比例缩小后取用
  if self.photoW > 300 then self.photoW = DEFAULTS.photoW end
  if self.photoH > 160 then self.photoH = DEFAULTS.photoH end

  self.dashboardH = (sk and sk:number("dashboard.normalHeight")) or 150
  -- 无配置时（dashboardH 取默认 150）应精确落在原锚点 440 上，
  -- 保证没有原版资源的用户视觉零变化
  self.dashboardY = self.sceneH - self.bottomBarH - self.dashboardH - 20
  if self.dashboardY < 300 then self.dashboardY = DEFAULTS.dashboardY end

  self.anchors = self:computeAnchors(self.n)
end

-- 1 号位是自己（底部居中），其余按「上边 → 左边 → 右边」分配
function Layout:computeAnchors(n)
  local a = {}
  if n <= 1 then
    a[1] = { self:centerX(self.photoW), self.dashboardY }
    return a
  end

  -- 自己
  a[1] = { self:centerX(self.photoW), self.dashboardY }

  local others = n - 1
  local top = math.min(others, math.max(1, math.floor((others + 1) / 2)))
  local sides = others - top
  local left = math.ceil(sides / 2)
  local right = sides - left

  -- 上边：沿 x 居中排开
  local topY = self.roomPadding + 24
  local totalW = top * self.photoW + (top - 1) * self.hDist
  local startX = math.max(self.roomPadding, (self.sceneW - totalW) / 2)
  for i = 1, top do
    a[1 + i] = { startX + (i - 1) * (self.photoW + self.hDist), topY }
  end

  -- 左边：沿 y 向下排开
  local leftX = self.roomPadding
  local baseY = topY + self.photoH + self.vDist
  for i = 1, left do
    a[1 + top + i] = { leftX, baseY + (i - 1) * (self.photoH + self.vDist) }
  end

  -- 右边：沿 y 向下排开
  local rightX = self.sceneW - self.roomPadding - self.photoW
  for i = 1, right do
    a[1 + top + left + i] = { rightX, baseY + (i - 1) * (self.photoH + self.vDist) }
  end
  return a
end

function Layout:centerX(w)
  return math.floor((self.sceneW - (w or self.photoW)) / 2)
end

function Layout:anchor(seat)
  return self.anchors[seat] or { self.roomPadding, self.roomPadding }
end

function Layout:panelSize()
  return self.photoW, self.photoH
end

return Layout
