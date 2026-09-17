-- 文本截断工具：按 UTF-8 完整字符截断，供牌桌小面板/弹层控制行宽。
--
-- 为什么必须按字符：直接 string.sub 按字节砍会把 3 字节的中文劈成两半，
-- love.graphics.print 对非法字节序列直接抛
-- "UTF-8 decoding error: Invalid UTF-8"（AI 推测面板实测踩过）。
local Utf8 = require "src.core.utf8"

local TextFit = {}

-- 粗略估文本像素宽（小号字体 13px：中日韩字符约 13px，ASCII 约 7px）
function TextFit.width(s)
  local width = 0
  for ch in Utf8.sanitize(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    width = width + (#ch == 1 and 7 or 13)
  end
  return width
end

-- 按 UTF-8 完整字符截到 max_bytes 以内，结尾补省略号；不超长则原样返回。
-- 入参先消毒：上游（模型输出等）可能本身带非法字节。
function TextFit.truncate(s, max_bytes)
  s = Utf8.sanitize(s)
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
function TextFit.fit(s, max_px, font)
  s = Utf8.sanitize(tostring(s or "")):gsub("[\r\n\t]", " ")
  local function width(text)
    if font and font.getWidth then
      local ok, w = pcall(font.getWidth, font, text)
      if ok and type(w) == "number" then return w end
    end
    return TextFit.width(text)
  end
  if width(s) <= max_px then return s end
  if width("…") > max_px then return "" end
  local out = ""
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if width(out .. ch .. "…") > max_px then break end
    out = out .. ch
  end
  return out .. "…"
end

return TextFit
