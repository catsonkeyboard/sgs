-- 极简 JSON 解析（零依赖）
--
-- 只为本项目的皮肤配置服务，因此有一个特殊之处：原版 QSanguosha 的
-- skins/*.json 带有 C 风格注释头（`/* ... */`）和行注释（`// ...`），
-- 标准 JSON 解析器会直接报错，必须先剥离——且不能误伤字符串里的 `//`。
local Json = {}

local function stripComments(s)
  local out, i, n = {}, 1, #s
  local in_string = false
  while i <= n do
    local c = s:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if c == "\\" then
        out[#out + 1] = s:sub(i + 1, i + 1)
        i = i + 2
      elseif c == '"' then
        in_string = false
        i = i + 1
      else
        i = i + 1
      end
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      -- plain=true 时不能传 "%*/"，那会去找字面的 %*/ 而永远找不到
      local e = s:find("*/", i + 2, true)
      if not e then break end
      i = e + 2
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      local e = s:find("\n", i, true)
      if not e then break end
      i = e
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local ESCAPES = {
  n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
}

local parseValue

local function parseString(s, i)
  local out = {}
  i = i + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local n = s:sub(i + 1, i + 1)
      out[#out + 1] = ESCAPES[n] or n
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  error("JSON 字符串未闭合")
end

local function parseNumber(s, i)
  local num = s:sub(i):match("^-?%d+%.?%d*[eE]?[-+]?%d*")
  if not num or num == "" then
    error("无法解析的 JSON 数字 @ " .. i .. ": " .. s:sub(i, i + 20))
  end
  return tonumber(num), i + #num
end

parseValue = function(s, i)
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    else
      break
    end
  end
  local c = s:sub(i, i)

  if c == "{" then
    local t = {}
    i = i + 1
    while true do
      while s:sub(i, i):match("%s") do i = i + 1 end
      if s:sub(i, i) == "}" then return t, i + 1 end
      local k
      k, i = parseString(s, i)
      while s:sub(i, i):match("%s") do i = i + 1 end
      if s:sub(i, i) ~= ":" then error("JSON 对象缺少冒号 @ " .. i) end
      local v
      v, i = parseValue(s, i + 1)
      t[k] = v
      while s:sub(i, i):match("%s") do i = i + 1 end
      local d = s:sub(i, i)
      if d == "," then
        i = i + 1
      elseif d == "}" then
        return t, i + 1
      else
        error("JSON 对象缺少 } 或 , @ " .. i)
      end
    end
  elseif c == "[" then
    local a = {}
    i = i + 1
    while true do
      while s:sub(i, i):match("%s") do i = i + 1 end
      if s:sub(i, i) == "]" then return a, i + 1 end
      local v
      v, i = parseValue(s, i)
      a[#a + 1] = v
      while s:sub(i, i):match("%s") do i = i + 1 end
      local d = s:sub(i, i)
      if d == "," then
        i = i + 1
      elseif d == "]" then
        return a, i + 1
      else
        error("JSON 数组缺少 ] 或 , @ " .. i)
      end
    end
  elseif c == '"' then
    return parseString(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    return parseNumber(s, i)
  end
end

function Json.decode(text)
  if type(text) ~= "string" then return nil end
  local ok, result = pcall(parseValue, stripComments(text), 1)
  if not ok then return nil, result end
  return result
end

-- 供测试/调试：只剥注释不解析
Json.stripComments = stripComments

return Json
