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

function Layout:init(skin, n, panelW, panelH)
  self.skin = skin
  self.n = n or 4
  local sk = skin
  self.sceneW = (sk and sk:number("room.minimumSceneSize[0]", 0))
  if not self.sceneW or self.sceneW <= 0 then self.sceneW = DEFAULTS.sceneW end
  self.sceneH = DEFAULTS.sceneH

  -- 面板实际绘制尺寸由调用方（scene）给定。**布局与绘制必须用同一个尺寸**，
  -- 否则排版按 157 宽算、绘制画 210 宽，右侧面板会超出画布被裁掉。
  self.photoW = panelW or (sk and sk:number("photo.normalWidth")) or DEFAULTS.photoW
  self.photoH = panelH or (sk and sk:number("photo.normalHeight")) or DEFAULTS.photoH
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

-- 1 号位是自己（底部居中），其余沿**顺时针**分配：
-- 左列（自下而上）→ 顶排（从左到右）→ 右列（自上而下）。
-- 引擎回合按座位号 1→N 推进，视觉上必须构成一圈顺时针，
-- 否则出牌顺序看起来在桌上乱跳（用户实测反馈）。
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

  -- 顶排：沿 x 居中排开
  local topY = self.roomPadding + 24
  local totalW = top * self.photoW + (top - 1) * self.hDist
  local startX = math.max(self.roomPadding, (self.sceneW - totalW) / 2)

  local leftX = self.roomPadding
  local rightX = self.sceneW - self.roomPadding - self.photoW
  local baseY = topY + self.photoH + self.vDist
  local step = self.photoH + self.vDist

  -- 按顺时针收集槽位，再依次分配给座位 2..N
  local slots = {}
  for i = left, 1, -1 do -- 左列自下而上：紧挨自己的是座位 2
    slots[#slots + 1] = { leftX, baseY + (i - 1) * step }
  end
  for i = 1, top do -- 顶排从左到右
    slots[#slots + 1] = { startX + (i - 1) * (self.photoW + self.hDist), topY }
  end
  for i = 1, right do -- 右列自上而下：最后一个座位回到自己右手边
    slots[#slots + 1] = { rightX, baseY + (i - 1) * step }
  end
  for i, pos in ipairs(slots) do
    a[1 + i] = pos
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
