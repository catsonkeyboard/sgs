-- DIY 扩展加载器：把原版 QSanguosha 的扩展脚本（diy/*.lua）加载进引擎
--
-- 扩展脚本的形态（见 QSanguosha/extension-doc/1-Start.lua）：
--   extension = sgs.Package("包名")
--   武将      = sgs.General(extension, "key", "势力", 体力)
--   技能      = sgs.CreateOneCardViewAsSkill{ ... }
--   武将:addSkill(技能)
--   return { extension }
--
-- 加载器负责：置好 sgs 全局 → 在沙箱里跑脚本 → 收集返回的 Package
-- → 把 General 转成引擎的武将表注册进 Engine。
local API = require "src.compat.api" -- 安装 Room/Player 的原版 API 别名
API.install()
local sgs = require "src.compat.sgs"
local Cards = require "src.core.cards"
local Card = require "src.core.card"

local Loader = {}

-- 已加载的扩展（调试/测试用）
Loader.loaded = {}

-- 创建沙箱环境：以 _G 为只读基底，写操作落在私有表里，
-- 这样扩展脚本不会污染全局，但能用到 string/table/ipairs 等标准库。
local function makeEnv()
  local env = {}
  local mt = {
    __index = function(_, k) return _G[k] end,
    __newindex = function(t, k, v) rawset(t, k, v) end,
  }
  env.sgs = sgs
  env._G = env
  return setmetatable(env, mt)
end

-- 从文件加载一个扩展，返回 Package 列表
function Loader.loadFile(path)
  local chunk, err = loadfile(path)
  if not chunk then
    return nil, "无法解析 " .. path .. ": " .. tostring(err)
  end
  setfenv(chunk, makeEnv())
  local ok, result = pcall(chunk)
  if not ok then
    return nil, "执行 " .. path .. " 失败: " .. tostring(result)
  end
  if type(result) ~= "table" then
    return nil, path .. " 未返回 Package 列表"
  end
  return result
end

-- 把一个 Package 注册进引擎
function Loader.registerPackage(engine, pkg)
  local n_general, n_card = 0, 0
  for _, g in ipairs(pkg.generals or {}) do
    engine:registerGeneral({
      name = g.name,
      key = g.key or g.name,
      max_hp = g.max_hp,
      kingdom = g.kingdom,
      female = g.female,
      skills = g.skills,
      package = pkg.name,
    })
    n_general = n_general + 1
  end
  for _, c in ipairs(pkg.cards or {}) do
    if c.name and c.ctype ~= nil then
      Cards.define(c.name, c)
      n_card = n_card + 1
    end
  end
  return n_general, n_card
end

-- 扫描目录加载全部扩展；dir 相对 love 的存档/资源目录，或普通文件系统路径
function Loader.loadDirectory(engine, dir)
  local files = {}
  if love and love.filesystem and love.filesystem.getDirectoryItems then
    local ok, items = pcall(love.filesystem.getDirectoryItems, dir)
    if ok and items then
      for _, f in ipairs(items) do
        if f:match("%.lua$") then table.insert(files, dir .. "/" .. f) end
      end
      table.sort(files)
    end
  end
  -- 无 love 环境（headless 测试）时退回 io 遍历
  if #files == 0 then
    local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
    if p then
      for f in p:lines() do
        if f:match("%.lua$") then table.insert(files, dir .. "/" .. f) end
      end
      p:close()
    end
  end

  local report = {}
  for _, path in ipairs(files) do
    local packs, err = Loader.loadFile(path)
    if not packs then
      table.insert(report, { path = path, ok = false, err = err })
    else
      local ng, nc = 0, 0
      for _, pkg in ipairs(packs) do
        local a, b = Loader.registerPackage(engine, pkg)
        ng, nc = ng + a, nc + b
      end
      table.insert(report, {
        path = path, ok = true, packages = #packs,
        generals = ng, cards = nc,
      })
      table.insert(Loader.loaded, { path = path, packages = packs })
    end
  end
  return report
end

return Loader
