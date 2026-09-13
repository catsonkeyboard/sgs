-- 极简 OOP 基建（Lua 5.1 / LuaJIT 兼容，零依赖）
-- 用法: local Card = class("Card"); function Card:init(...) ... end; local c = Card.create(...)
local function class(name, super)
  local cls = {}
  cls.__index = cls
  cls.__name = name
  cls.super = super
  if super then
    setmetatable(cls, { __index = super })
  end
  function cls.create(...)
    local obj = setmetatable({}, cls)
    obj:init(...)
    return obj
  end
  return cls
end

return class
