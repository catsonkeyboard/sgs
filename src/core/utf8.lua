-- UTF-8 消毒：把非法字节序列替换成 U+FFFD（�），保证任何文本都能安全
-- 交给 love.graphics.print（对非法序列直接抛 UTF-8 decoding error）。
--
-- 为什么在 core：日志（Room:log）可能收到任意来源的文本（LLM 输出、
-- DIY 扩展、网络消息），坏字节必须在入库时拦下，而不是每个打印点各自防。
-- 纯 Lua 实现，零依赖，headless 可测。
local Utf8 = {}

local REPLACEMENT = "\239\191\189" -- U+FFFD

-- 逐字节走一遍：多字节序列校验长度与续字节（10xxxxxx），
-- 不合法的落在替换符上。合法内容原样通过（含 4 字节 emoji）。
function Utf8.sanitize(s)
  s = tostring(s or "")
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 128 then
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    elseif b >= 192 then
      local len = (b >= 240) and 4 or (b >= 224) and 3 or 2
      local valid = (i + len - 1 <= n)
      if valid then
        for j = i + 1, i + len - 1 do
          local c = s:byte(j)
          if not c or c < 128 or c >= 192 then valid = false break end
        end
      end
      if valid then
        out[#out + 1] = s:sub(i, i + len - 1)
        i = i + len
      else
        out[#out + 1] = REPLACEMENT
        i = i + 1
      end
    else
      -- 孤立续字节（10xxxxxx 打头）
      out[#out + 1] = REPLACEMENT
      i = i + 1
    end
  end
  return table.concat(out)
end

return Utf8
