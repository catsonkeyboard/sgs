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

-- 播放一个已解析出的相对路径（内部用）。
-- 返回音源实例（供 voiceBusy 判断台词是否还在播）；失败返回 false。
function Audio:_playRel(rel)
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
  if ok and inst then return inst end
  return false
end

function Audio:play(key, gender)
  if not self.enabled or self.muted or not key then return false end
  if not (love and love.audio) then return false end -- headless 无音频
  local rel = self.skin:sound(key, gender)
  return self:_playRel(rel)
end

-- 技能台词：技能名是中文，由 Skin:skillSound 查拼音键（带 1/2 两个版本）。
-- 台词要独占播放：记录音源，演示队列在它结束前不推进（防语音串音）。
function Audio:playSkill(skillName)
  if not self.enabled or self.muted or not skillName then return false end
  if not (love and love.audio) then return false end
  if not (self.skin and self.skin.skillSound) then return false end
  local inst = self:_playRel(self.skin:skillSound(skillName))
  if inst then self.voice = inst end
  return inst or false
end

-- 阵亡语音等同样按「台词」处理（键为拼音，走 Skin:sound）
function Audio:playVoice(key)
  local inst = self:play(key)
  if inst then self.voice = inst end
  return inst or false
end

-- 当前是否有台词还在播放（headless / 播放失败时恒为 false）
function Audio:voiceBusy()
  if not (self.voice and love and love.audio) then return false end
  local ok, playing = pcall(function() return self.voice:isPlaying() end)
  return ok and playing == true
end

-- 卡牌音效：引擎的牌名 → 原版音频键名不一致的在这里翻译
-- （闪在引擎里叫 dodge，原版音频文件叫 jink.ogg）。
-- gender 用于选 audio/card/<male|female>/ 目录，出牌人不同音色不同。
local CARD_SOUND_KEY = { dodge = "jink" }

function Audio:playCard(cardName, gender)
  if not cardName then return false end
  -- 杀/闪等也是人物语音，同样参与等待，不能与后续技能台词叠播。
  local inst = self:play(CARD_SOUND_KEY[cardName] or cardName, gender)
  if inst then self.voice = inst end
  return inst
end

-- 装备音效：引擎槽位（weapon/armor/offensive_horse/defensive_horse）
-- → 音频键（audio/card/common/{weapon,armor,horse}.ogg）
local EQUIP_SOUND_KEY = {
  weapon = "weapon",
  armor = "armor",
  offensive_horse = "horse",
  defensive_horse = "horse",
}

function Audio:playEquip(slot)
  if not slot then return false end
  return self:play(EQUIP_SOUND_KEY[slot] or slot)
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
