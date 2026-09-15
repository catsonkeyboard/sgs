-- 主菜单场景：标题 + 模式选择
-- 视觉：暗色水墨底 + 描金内外框与角饰 + 金字标题（印章点缀）+
--       势力标识行 + 居中自适应按钮（悬停高亮）。
-- 布局随窗口尺寸居中自适应（relayout），点击判定与绘制用同一套矩形。
local class = require "src.class"

local MenuScene = class("MenuScene")

-- 按钮配色（基础色，悬停时叠一层白提亮）
local BTN_RED = { 0.62, 0.16, 0.13 }   -- 身份局
local BTN_BLUE = { 0.16, 0.28, 0.40 }  -- 1v1
local BTN_TEAL = { 0.13, 0.31, 0.26 }  -- 联机
local BTN_SLATE = { 0.13, 0.20, 0.26 } -- 开关类
local GOLD = { 0.94, 0.82, 0.45 }
local GOLD_DIM = { 0.78, 0.66, 0.35 }

-- 势力标识：颜色取标准版惯例（魏蓝 / 蜀红 / 吴绿 / 群灰）
local KINGDOMS = {
  { zh = "魏", color = { 0.35, 0.47, 0.71 } },
  { zh = "蜀", color = { 0.75, 0.22, 0.17 } },
  { zh = "吴", color = { 0.25, 0.62, 0.39 } },
  { zh = "群", color = { 0.55, 0.56, 0.49 } },
}

function MenuScene:init(on_start, on_net)
  self.on_start = on_start
  self.on_net = on_net
  local font_path = "assets/font/DroidSansFallback.ttf"
  self.font_title = love.graphics.newFont(font_path, 64)
  self.font_seal = love.graphics.newFont(font_path, 34)
  self.font_wm = love.graphics.newFont(font_path, 300)
  self.font = love.graphics.newFont(font_path, 18)
  self.font_sm = love.graphics.newFont(font_path, 13)

  -- 身份局按规模分档：
  --   **5 人是默认**（主1 忠1 反2 内1，节奏适中，一局不拖沓）
  --   8 人是官方标准局（主1 忠2 反4 内1），身份博弈最完整，推荐人多时玩
  --   4 人是最小可玩局
  -- 坐标由 relayout 按窗口尺寸填写，这里只声明内容。
  self.buttons = {
    { text = "身份局（5 人）", mode = "identity", size = 5,
      desc = "默认 · 主1 忠1 反2 内1", color = BTN_RED },
    { text = "身份局（8 人）", mode = "identity", size = 8,
      desc = "推荐 · 主1 忠2 反4 内1", color = BTN_RED },
    { text = "身份局（4 人）", mode = "identity", size = 4,
      desc = "主1 忠1 反1 内1", color = BTN_RED },
    { text = "1v1 死斗", mode = "duel", size = 2,
      desc = "标准牌堆 · 两人对决", color = BTN_BLUE },
    { text = "联机对战", net = true,
      desc = "联机前先跑 ./tools/serve.sh", color = BTN_TEAL },
  }

  -- AI 托管：循环切换三档。牌桌里还能按数字键随时改单个座位。
  self.ai_modes = {
    { key = "off",    label = "关",     desc = "全部由人和规则 BOT 操作" },
    { key = "others", label = "其他座位", desc = "除你以外的座位交给 LLM 决策" },
    { key = "all",    label = "全部",   desc = "连你的座位也交给 AI（观战模式）" },
  }
  self.ai_index = 1
  self.ai_button = { w = 380, h = 48, ai_toggle = true, on = false,
    color = BTN_SLATE, text = "AI 托管：关", desc = "" }
  self:refreshAIButton()

  -- 开局选将（文档开局流程：主公 5 选 1、其余 3 选 1）；关 = 沿用随机分将
  self.draft_on = true
  self.draft_button = { w = 380, h = 48, draft_toggle = true, on = true,
    color = BTN_SLATE, text = "开局选将：开", desc = "" }
  self:refreshDraftButton()

  self.t = 0
  self:relayout(1130, 650)
end

-- 居中自适应布局：三行按钮（身份局一排 / 1v1+联机一排 / 两个开关一排）。
-- draw 每帧按实际窗口重算，点击判定读同一套矩形。
function MenuScene:relayout(w, h)
  -- 第一行：三张身份局按钮
  local aw, gap = 226, 22
  local ax = (w - (3 * aw + 2 * gap)) / 2
  for i, b in ipairs(self.buttons) do
    if b.mode == "identity" then
      b.w, b.h = aw, 66
      b.x, b.y = ax + (i - 1) * (aw + gap), math.floor(h * 0.48)
    end
  end
  -- 第二行：1v1 与联机
  local bw, gap2 = 320, 28
  local bx = (w - (2 * bw + gap2)) / 2
  self.buttons[4].w, self.buttons[4].h = bw, 58
  self.buttons[4].x, self.buttons[4].y = bx, math.floor(h * 0.48) + 88
  self.buttons[5].w, self.buttons[5].h = bw, 58
  self.buttons[5].x, self.buttons[5].y = bx + bw + gap2, math.floor(h * 0.48) + 88
  -- 第三行：两个开关
  local cw, gap3 = 380, 24
  local cx = (w - (2 * cw + gap3)) / 2
  local cy = math.floor(h * 0.48) + 170
  self.ai_button.x, self.ai_button.y = cx, cy
  self.draft_button.x, self.draft_button.y = cx + cw + gap3, cy
  self.row_y = math.floor(h * 0.48) -- 供 draw 画开关说明行
end

function MenuScene:refreshAIButton()
  local m = self.ai_modes[self.ai_index]
  self.ai_button.text = "AI 托管：" .. m.label
  self.ai_button.desc = m.desc .. "（需设置 SGS_AI_URL / SGS_AI_KEY）"
  self.ai_button.on = self.ai_index ~= 1
end

function MenuScene:refreshDraftButton()
  self.draft_button.text = "开局选将：" .. (self.draft_on and "开" or "关")
  self.draft_button.desc = self.draft_on
    and "主公 5 选 1、其余 3 选 1（文档开局流程）"
    or "随机分将（跳过选将直接开局）"
  self.draft_button.on = self.draft_on
end

function MenuScene:update(dt)
  self.t = self.t + (dt or 0)
  -- 悬停高亮：轮询鼠标位置（headless / 打桩环境无 love.mouse 时跳过）
  if love and love.mouse and love.mouse.getPosition then
    local ok, mx, my = pcall(love.mouse.getPosition)
    if ok then self.mx, self.my = mx, my end
  end
end

local function pointIn(b, x, y)
  return b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
end

-- 一枚按钮：投影 + 底色 + 顶部提亮 + 描金边 + 标题/说明两行
function MenuScene:drawButton(b)
  local hover = self.mx and pointIn(b, self.mx, self.my)
  local x, y, w, h = b.x, b.y, b.w, b.h
  -- 投影
  love.graphics.setColor(0, 0, 0, 0.35)
  love.graphics.rectangle("fill", x + 3, y + 4, w, h, 12, 12)
  -- 底色与悬停提亮
  local c = b.color or BTN_SLATE
  love.graphics.setColor(c[1], c[2], c[3], hover and 1 or 0.92)
  love.graphics.rectangle("fill", x, y, w, h, 12, 12)
  if hover then
    love.graphics.setColor(1, 1, 1, 0.10)
    love.graphics.rectangle("fill", x, y, w, h, 12, 12)
  end
  -- 顶部一条更亮的横带，做出受光感
  love.graphics.setColor(1, 1, 1, 0.07)
  love.graphics.rectangle("fill", x, y, w, h * 0.42, 12, 12)
  -- 描金边框（悬停时更亮更粗）
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], hover and 0.95 or 0.55)
  if love.graphics.setLineWidth then love.graphics.setLineWidth(hover and 2 or 1) end
  love.graphics.rectangle("line", x, y, w, h, 12, 12)
  if love.graphics.setLineWidth then love.graphics.setLineWidth(1) end
  -- 文案：大字标题 + 小字说明（开关类单行居中）
  love.graphics.setColor(0.97, 0.95, 0.88)
  if b.ai_toggle or b.draft_toggle then
    -- 状态点：开 = 金色，关 = 暗灰
    love.graphics.setColor(b.on and GOLD or { 0.45, 0.48, 0.45 })
    love.graphics.circle("fill", x + 26, y + h / 2, 5)
    love.graphics.setColor(0.97, 0.95, 0.88)
    love.graphics.setFont(self.font)
    love.graphics.printf(b.text, x + 26, y + (h - 18) / 2, w - 26, "center")
  else
    love.graphics.setFont(self.font)
    love.graphics.printf(b.text, x, y + 12, w, "center")
    love.graphics.setColor(0.88, 0.85, 0.75, 0.8)
    love.graphics.setFont(self.font_sm)
    love.graphics.printf(b.desc, x, y + 40, w, "center")
  end
end

function MenuScene:draw()
  local w, h = love.graphics.getDimensions()
  self:relayout(w, h)

  -- ===== 背景：深墨绿的纵向明暗 + 巨字水印 =====
  local strips = 48
  for i = 0, strips - 1 do
    local t = i / (strips - 1)
    local lum = 0.055 + 0.045 * math.sin(t * math.pi) -- 中间略亮，上下压暗
    love.graphics.setColor(0.055, lum + 0.075, 0.05)
    love.graphics.rectangle("fill", 0, h * t, w, h / strips + 1)
  end
  local breath = 0.045 + 0.012 * math.sin(self.t * 1.6) -- 呼吸感的水印
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], breath)
  love.graphics.setFont(self.font_wm)
  love.graphics.printf("杀", 0, h * 0.52 - 170, w, "center")

  -- ===== 描金内外框与四角饰线 =====
  love.graphics.setColor(GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.30)
  love.graphics.rectangle("line", 14, 14, w - 28, h - 28, 4, 4)
  love.graphics.setColor(GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.12)
  love.graphics.rectangle("line", 22, 22, w - 44, h - 44, 4, 4)
  if love.graphics.line then
    love.graphics.setColor(GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.5)
    if love.graphics.setLineWidth then love.graphics.setLineWidth(2) end
    local m = 14
    for _, c in ipairs({ { m, m, 1, 1 }, { w - m, m, -1, 1 },
                         { m, h - m, 1, -1 }, { w - m, h - m, -1, -1 } }) do
      love.graphics.line(c[1], c[2], c[1] + 26 * c[3], c[2])
      love.graphics.line(c[1], c[2], c[1], c[2] + 26 * c[4])
    end
    if love.graphics.setLineWidth then love.graphics.setLineWidth(1) end
  end

  -- ===== 标题：描边金字 + 朱红印章 =====
  local title_y = math.max(56, h * 0.12)
  love.graphics.setFont(self.font_title)
  love.graphics.setColor(0.04, 0.02, 0.01, 0.9)
  for _, off in ipairs({ { 3, 0 }, { -3, 0 }, { 0, 3 }, { 0, -3 } }) do
    love.graphics.printf("三 国 杀", off[1], title_y + off[2], w, "center")
  end
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("三 国 杀", 0, title_y, w, "center")

  local seal_s = 46
  local seal_x = w / 2 + 128
  local seal_y = title_y + 30
  love.graphics.setColor(0.64, 0.16, 0.12, 0.95)
  love.graphics.rectangle("fill", seal_x, seal_y, seal_s, seal_s, 6, 6)
  love.graphics.setColor(1, 0.96, 0.9, 0.85)
  love.graphics.rectangle("line", seal_x + 4, seal_y + 4, seal_s - 8, seal_s - 8, 4, 4)
  love.graphics.setFont(self.font_seal)
  love.graphics.printf("杀", seal_x, seal_y + 7, seal_s, "center")

  -- 副标题与两侧饰线
  local sub_y = title_y + 86
  love.graphics.setColor(0.72, 0.76, 0.68)
  love.graphics.setFont(self.font)
  love.graphics.printf("sgs-love · 标准牌堆 · 身份局 / 1v1 / 联机", 0, sub_y, w, "center")
  if love.graphics.line then
    love.graphics.setColor(GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.35)
    love.graphics.line(w / 2 - 320, sub_y + 10, w / 2 - 150, sub_y + 10)
    love.graphics.line(w / 2 + 150, sub_y + 10, w / 2 + 320, sub_y + 10)
  end

  -- ===== 势力标识行：菱形底 + 势力字 =====
  local ky = sub_y + 52
  love.graphics.setFont(self.font_sm)
  for i, k in ipairs(KINGDOMS) do
    local kx = w / 2 + (i - 2.5) * 72
    love.graphics.setColor(k.color[1], k.color[2], k.color[3], 0.9)
    love.graphics.polygon("fill",
      kx, ky - 15, kx + 15, ky, kx, ky + 15, kx - 15, ky)
    love.graphics.setColor(0.05, 0.08, 0.05, 0.55)
    love.graphics.polygon("line",
      kx, ky - 15, kx + 15, ky, kx, ky + 15, kx - 15, ky)
    love.graphics.setColor(0.97, 0.95, 0.88, 0.95)
    love.graphics.printf(k.zh, kx - 16, ky - 8, 32, "center")
  end

  -- ===== 按钮 =====
  for _, b in ipairs(self.buttons) do
    self:drawButton(b)
  end
  -- 开关的说明挂在按钮下方
  love.graphics.setColor(0.62, 0.66, 0.60)
  love.graphics.setFont(self.font_sm)
  for _, b in ipairs({ self.ai_button, self.draft_button }) do
    self:drawButton(b)
    love.graphics.printf(b.desc, b.x - 40, self.row_y + 170 + b.h + 8, b.w + 80, "center")
  end

  -- ===== 页脚 =====
  love.graphics.setColor(0.5, 0.55, 0.5)
  love.graphics.setFont(self.font_sm)
  love.graphics.printf("LÖVE 11.5 · 从 QSanguosha (C++/Qt) 迁移", 0, h - 34, w, "center")
  love.graphics.setColor(1, 1, 1, 1)
end

function MenuScene:mousepressed(x, y, button)
  if button ~= 1 then return end

  local ab = self.ai_button
  if pointIn(ab, x, y) then
    self.ai_index = (self.ai_index % #self.ai_modes) + 1
    self:refreshAIButton()
    return
  end

  local db = self.draft_button
  if pointIn(db, x, y) then
    self.draft_on = not self.draft_on
    self:refreshDraftButton()
    return
  end

  for _, b in ipairs(self.buttons) do
    if pointIn(b, x, y) then
      if b.net then
        if self.on_net then self.on_net() end
      else
        self.on_start(b.mode, b.size, self.ai_modes[self.ai_index].key,
          self.draft_on)
      end
      return
    end
  end
end

return MenuScene
