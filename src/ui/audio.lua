-- 音频：按原版 skins/defaultSkin.audio.json 的键名播放音效
--
-- 两条原则：
--   1) **音频永远不能影响游戏逻辑**。缺文件、缺 love.audio、headless 环境下
--      一律静默降级，绝不抛错、绝不打断对局。
--   2) 音源按需加载并缓存；同名音效并发播放时克隆一个新 source，
--      避免后一次播放打断前一次。
local class = require "src.class"
local Skin = require "src.ui.skin"

local Audio = class("Audio")

function Audio:init(skin)
  self.skin = skin or Skin.create()
  self.cache = {}
  self.enabled = true
  self.volume = 0.6
  self.muted = false
end

-- 该键在原版 audio.json 里是否真的有映射
function Audio:has(key)
  return self.skin:sound(key) ~= nil
end

local function loadSource(path)
  if not (love and love.audio and love.filesystem) then return nil end
  local ok, info = pcall(love.filesystem.getInfo, path)
  if not ok or not info then return nil end
  local ok2, src = pcall(love.audio.newSource, path, "static")
  if not ok2 or not src then return nil end
  return src
end

function Audio:play(key)
  if not self.enabled or self.muted or not key then return false end
  if not (love and love.audio) then return false end -- headless 无音频
  local rel = self.skin:sound(key)
  if not rel then return false end
  local path = self.skin:path(rel)
  if not path then return false end

  local src = self.cache[path]
  if src == nil then
    src = loadSource(path)
    self.cache[path] = src or false -- 记 false 表示「已知不可用」，避免反复探测
  end
  if not src then return false end

  -- 同时播放多个实例：克隆一份，避免打断上一个
  local ok, inst = pcall(function()
    local s = src:clone()
    s:setVolume(self.volume)
    s:play()
    return s
  end)
  return ok and inst ~= nil
end

-- 按卡牌名播放使用音效（原版键名形如 "slash"、"peach"）
function Audio:playCard(cardName)
  return self:play(cardName)
end

function Audio:setVolume(v)
  self.volume = math.max(0, math.min(1, v or 0))
end

function Audio:setMuted(m) self.muted = m and true or false end
function Audio:setEnabled(e) self.enabled = e and true or false end

-- 默认实例（UI 层直接用）
local default = nil
function Audio.default()
  if not default then default = Audio.create() end
  return default
end

return Audio
