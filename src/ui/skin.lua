-- 皮肤配置层：读取原版 QSanguosha 的 skins/*.json
--
-- 设计要点：
--   1) **资源根目录可配置，缺失时全部安全降级**。headless 测试、以及没有
--      QSanguosha 源码的机器上，所有查询返回 nil，调用方走内置默认值，绝不崩。
--   2) 原版 json 带注释，用 src/ui/json.lua 解析。
--   3) 图片/音频只给**路径**，加载由调用方（UI 层）按需做——core 与 skin
--      都不碰 love.graphics / love.audio。
local class = require "src.class"
local Json = require "src.ui.json"

local Skin = class("Skin")

-- 资源根：**默认用项目自带的 assets/**，不再引用原 QSanguosha 源码目录。
-- 仅当显式设置 SGS_ASSET_ROOT 时才指向别处（便于调试或用完整原版资源）。
-- 注意：这里只能用 io.open，不能用下面的 readFile —— 那是个 local，
-- 声明在 findRoot 之后，此处不在其作用域内。
local function hasLayout(root)
  local f = io.open(root .. "/skins/defaultSkin.layout.json", "r")
  if not f then return false end
  f:close()
  return true
end

local function findRoot()
  local env = os.getenv("SGS_ASSET_ROOT")
  if env and env ~= "" and hasLayout(env) then return env end
  for _, r in ipairs({ "assets", "./assets" }) do
    if hasLayout(r) then return r end
  end
  return nil
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function loadJson(root, name)
  if not root then return {} end
  local content = readFile(root .. "/" .. name)
  if not content then return {} end
  local ok, t = pcall(Json.decode, content)
  if not ok or type(t) ~= "table" then return {} end
  return t
end

function Skin:init(root)
  self.root = root or findRoot()
  self.layout = loadJson(self.root, "skins/defaultSkin.layout.json")
  self.imageMap = loadJson(self.root, "skins/defaultSkin.image.json")
  self.audioMap = loadJson(self.root, "skins/defaultSkin.audio.json")
  self.animation = loadJson(self.root, "skins/defaultSkin.animation.json")
  self.cardSizes = (self.layout and self.layout.common) or {}
end

-- 按 "a.b.c" 路径取值
local function getPath(t, path)
  if type(t) ~= "table" then return nil end
  local cur = t
  for part in string.gmatch(path, "[^%.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[part]
  end
  return cur
end

function Skin:number(path, default)
  local v = getPath(self.layout, path)
  if type(v) == "number" then return v end
  return default
end

-- 原版布局里的区域一律是 [x, y, w, h]
function Skin:rect(path)
  local v = getPath(self.layout, path)
  if type(v) == "table" and #v >= 4 then return v end
  return nil
end

-- 图片：值可能是 "path" 或 ["path", [x,y,w,h]]，也可能带 %1 占位符
function Skin:image(key, ...)
  local v = self.imageMap[key]
  if type(v) == "string" then
    return self:_fill(v, ...)
  elseif type(v) == "table" then
    if type(v[1]) == "string" then return self:_fill(v[1], ...) end
  end
  return nil
end

function Skin:_fill(str, ...)
  local args = { ... }
  local i = 0
  local out = string.gsub(str, "%%(%d)", function(d)
    return tostring(args[tonumber(d)] or ("%" .. d))
  end)
  return out
end

-- 资源根下的绝对路径
function Skin:path(relative)
  if not (self.root and relative) then return nil end
  return self.root .. "/" .. relative
end

-- 卡牌图片：原版 image.json 没有逐张卡的映射，靠目录约定
--   基本牌/锦囊：image/card/slash.png（snake_case）
--   装备：      image/card/Crossbow.png（CamelCase）
local CARD_CAMEL = {
  crossbow = "Crossbow", axe = "Axe", blade = "Blade",
  ["double_sword"] = "DoubleSword", ["qinggang_sword"] = "QingGang",
  ["spear"] = "Spear", ["halberd"] = "Halberd", ["kylin_bow"] = "KylinBow",
  ["eight_diagram"] = "EightDiagram", ["silver_lion"] = "SilverLion",
  ["vine"] = "Vine", ["renwang_shield"] = "RenWangShield",
  ["chitu"] = "ChiTu", ["dayuan"] = "DaYuan", ["dilu"] = "DiLu",
  ["jueying"] = "JueYing", ["zhuahuangfeidian"] = "ZhuaHuangFeiDian",
  ["dilu_horse"] = "DiLu",
}

function Skin:cardImage(cardName)
  if not (self.root and cardName) then return nil end
  local candidates = {
    "image/card/" .. cardName .. ".png",
    "image/card/" .. cardName .. ".jpg",
  }
  local camel = CARD_CAMEL[cardName]
  if camel then
    table.insert(candidates, 1, "image/card/" .. camel .. ".png")
  else
    -- 没登记的也试一次首字母大写形式
    local upper = string.gsub(cardName, "^%l", string.upper)
    table.insert(candidates, 1, "image/card/" .. upper .. ".png")
  end
  for _, rel in ipairs(candidates) do
    local p = self.root .. "/" .. rel
    if readFile(p) then return rel end
  end
  return nil
end

-- 桌面背景：image.json 的 tableBg 指向 backdrop/default.jpg，
-- 但资源里实际是 backdrop/table.jpg，因此按多个候选依次尝试。
function Skin:tableBackground()
  if not self.root then return nil end
  local candidates = {}
  local v = self.imageMap and self.imageMap.tableBg
  if type(v) == "string" then
    table.insert(candidates, v)
    table.insert(candidates, "image/" .. v)
  end
  table.insert(candidates, "image/backdrop/table.jpg")
  table.insert(candidates, "image/backdrop/bg.jpg")
  table.insert(candidates, "image/backdrop/default.jpg")
  for _, rel in ipairs(candidates) do
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 仪表盘框体（原版 dashboardLeftFrame / dashboardRightBase 等）
function Skin:frame(key)
  return self:image(key)
end

-- 武将头像：原版按拼音命名（image/generals/avatar/caocao.png），
-- 正好对应本引擎 general.key。依次尝试 avatar / card / big 三种尺寸。
local GENERAL_DIRS = {
  "image/generals/avatar/%s.png",
  "image/generals/card/%s.jpg",
  "image/generals/big/%s.png",
}

function Skin:generalImage(key)
  if not (self.root and key) then return nil end
  for _, fmt in ipairs(GENERAL_DIRS) do
    local rel = string.format(fmt, key)
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 勾玉（体力）：image/system/magatamas/{0,1,2,3}.png，0 空 3 满
function Skin:magatamaImage(kind)
  if not self.root then return nil end
  local rel = "image/system/magatamas/" .. tostring(kind) .. ".png"
  if readFile(self.root .. "/" .. rel) then return rel end
  return nil
end

-- 势力图标：原版放在 image/kingdom/icon/ 下（不是 image/kingdom/ 根）
function Skin:kingdomImage(kingdom)
  if not (self.root and kingdom) then return nil end
  for _, rel in ipairs({
    "image/kingdom/icon/" .. kingdom .. ".png",
    "image/kingdom/corner/" .. kingdom .. ".png",
  }) do
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 音频：某事件的音效可能有多个，随机取一个。
--
-- 重要：`defaultSkin.audio.json` 在这个皮肤里**是空的**（与 animation.json 一样），
-- 只查配置会永远返回 nil —— 音频等于没接。因此这里按原版资源目录的约定兜底：
--   audio/card/<male|female>/<card_name>.ogg   出牌音效
--   audio/system/<key>.ogg                     系统音效（injure1 / hplost / lose ...）
--   audio/skill/<key>.ogg                      技能音效
--   audio/death/<general_key>.ogg              阵亡语音
local SYSTEM_SOUND = {
  injure = { "injure1", "injure2", "injure3" },
  hplost = { "hplost" },
  chained = { "chained" },
  lose = { "lose" },
  win = { "win" },
  choose_item = { "choose-item" },
}

local function pick(pool)
  if #pool == 0 then return nil end
  return pool[math.random(#pool)]
end

function Skin:sound(key, gender)
  -- 1) 配置优先
  local v = self.audioMap[key]
  if type(v) == "string" then return v end
  if type(v) == "table" then
    local pool = {}
    for _, item in ipairs(v) do
      if type(item) == "string" then
        table.insert(pool, item)
      elseif type(item) == "table" and type(item[1]) == "string" then
        table.insert(pool, item[1])
      end
    end
    local r = pick(pool)
    if r then return r end
  end
  if not self.root then return nil end

  -- 2) 系统音效
  if SYSTEM_SOUND[key] then
    local n = pick(SYSTEM_SOUND[key])
    local rel = "audio/system/" .. n .. ".ogg"
    if readFile(self.root .. "/" .. rel) then return rel end
  end

  -- 3) 卡牌音效（按性别分目录，回落 common）
  local dirs = { gender == "female" and "female" or "male", "common" }
  for _, d in ipairs(dirs) do
    local rel = string.format("audio/card/%s/%s.ogg", d, key)
    if readFile(self.root .. "/" .. rel) then return rel end
  end

  -- 4) 技能 / 阵亡
  for _, fmt in ipairs({ "audio/skill/%s.ogg", "audio/death/%s.ogg" }) do
    local rel = string.format(fmt, key)
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 是否真的接上了原版资源
function Skin:available()
  return self.root ~= nil and next(self.layout) ~= nil
end

return Skin
