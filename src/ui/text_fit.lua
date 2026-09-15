-- 文本截断工具：按 UTF-8 完整字符截断，供牌桌小面板/弹层控制行宽。
--
-- 为什么必须按字符：直接 string.sub 按字节砍会把 3 字节的中文劈成两半，
-- love.graphics.print 对非法字节序列直接抛
-- "UTF-8 decoding error: Invalid UTF-8"（AI 推测面板实测踩过）。
local TextFit = {}

-- 粗略估文本像素宽（小号字体 13px：中日韩字符约 13px，ASCII 约 7px）
function TextFit.width(s)
  local cjk = select(2, s:gsub("[^\128-\191]", ""))
  return cjk * 13 + (#s - cjk * 3) * 7
end

-- 按 UTF-8 完整字符截到 max_bytes 以内，结尾补省略号；不超长则原样返回
function TextFit.truncate(s, max_bytes)
  s = tostring(s or "")
  if #s <= max_bytes then return s end
  local cut = max_bytes
  -- 回退到字符边界：128..191 的字节是上一字符的续字节
  while cut > 1 do
    local b = string.byte(s, cut)
    if b and b >= 128 and b < 192 then
      cut = cut - 1
    else
      break
    end
  end
  return s:sub(1, cut - 1) .. "…"
end

-- 控制在一行像素宽内：逐次收紧字节预算直到宽度达标
function TextFit.fit(s, max_px)
  s = tostring(s or "")
  if TextFit.width(s) <= max_px then return s end
  local bytes = math.floor(max_px / 13 * 3)
  while bytes > 3 do
    local t = TextFit.truncate(s, bytes)
    if TextFit.width(t) <= max_px then return t end
    bytes = bytes - 3
  end
  return "…"
end

return TextFit
