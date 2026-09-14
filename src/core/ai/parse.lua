-- AI 响应解析与校验：把 LLM 的输出翻译成引擎能吃的响应
--
-- 这里的态度是「默认 LLM 会犯错」：
--   - 它可能裹 markdown 代码块、前后加废话、给字符串编号、越界、给错数量；
--   - 它给的动作在解析时也可能已经失效（理论上协程停在 yield 不会变，
--     但 view_as 生成的虚拟牌、转化技的可用性都有边界情况）。
-- 因此每一步都返回 (响应, 错误原因)，任何一个环节不对就交给上层回落 BOT。
-- 宁可让 AI 这一手打得平庸，也不能让它把游戏卡死或搞出非法状态。
local Json = require "src.core.json"

local Parse = {}

-- 从 LLM 的原始输出里抠出第一个 JSON 对象。
-- 实测最常见的三种污染：```json 代码块、前后寒暄、JSON 后面跟解释。
local function extractJson(raw)
  if type(raw) ~= "string" then return nil end
  local s = raw:gsub("```%w*", "")
  local i = s:find("{", 1, true)
  if not i then return nil end
  local depth, j, in_str, esc = 0, i, false, false
  while j <= #s do
    local c = s:sub(j, j)
    if in_str then
      if esc then esc = false
      elseif c == "\\" then esc = true
      elseif c == '"' then in_str = false end
    elseif c == '"' then in_str = true
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then break end
    end
    j = j + 1
  end
  if depth ~= 0 then return nil end
  return Json.decode(s:sub(i, j))
end
Parse.extractJson = extractJson

local function playerBySeat(room, seat)
  if not seat then return nil end
  for _, p in ipairs(room.players) do
    if p.seat == seat then return p end
  end
  return nil
end

-- 归一化成编号数组：支持 {"action":3} 与 {"actions":[1,2]} 两种写法，
-- 编号是字符串（"3"）也要认——LLM 偶尔会加引号。
local function normalizeIds(data)
  local raw = data.actions
  if raw == nil and data.action ~= nil then raw = { data.action } end
  if type(raw) ~= "table" then
    if type(raw) == "number" or type(raw) == "string" then raw = { raw } else return nil end
  end
  if #raw == 0 then return nil end
  local out = {}
  for _, v in ipairs(raw) do
    local n = tonumber(v)
    if not n then return nil end
    out[#out + 1] = n
  end
  return out
end

-- 每个请求类型期望选几个动作
local EXPECTED_COUNT = {
  askForUseCard = 1, askForCard = 1, askForChooseCard = 1,
  askForDiscardFrom = 1, askForSkillInvoke = 1, askForChoice = 1,
}

-- 主入口：raw 是 LLM 原始字符串，actions 是 Actions.enumerate 的结果
-- 返回 (响应, nil) 或 (nil, 错误原因)
function Parse.response(raw, req, room, actions)
  local me = req.player
  local data = extractJson(raw)
  if type(data) ~= "table" then return nil, "输出不是合法 JSON" end

  local ids = normalizeIds(data)
  if not ids then return nil, "缺少 action/actions 字段" end

  local picked = {}
  for _, id in ipairs(ids) do
    local a = type(id) == "number" and actions[id] or nil
    if not a then return nil, string.format("动作编号越界: %s", tostring(id)) end
    picked[#picked + 1] = a
  end

  -- 数量校验：弃牌要正好 n 张，其余请求只能选一个
  if req.type == "askForDiscard" then
    if #picked ~= (req.n or 0) then
      return nil, string.format("弃牌数量不符：需要 %d 张，给了 %d 个", req.n or 0, #picked)
    end
  else
    local want = EXPECTED_COUNT[req.type] or 1
    if #picked ~= want then
      return nil, string.format("动作数量不符：需要 %d 个，给了 %d 个", want, #picked)
    end
  end

  -- 混合类型一律拒绝：说明 LLM 没看懂，交给 BOT 更稳
  local kind = picked[1].kind
  for _, a in ipairs(picked) do
    if a.kind ~= kind then return nil, "一次选了不同类型的动作" end
  end

  if kind == "pass" then return nil, nil end

  if kind == "use" then
    local a = picked[1]
    if not a.card then return nil, "动作缺少卡牌" end
    local target = playerBySeat(room, a.target_seat)
    if not target then return nil, "目标座位不存在" end
    if target ~= me then
      local ok, why = room:canUseCardOn(me, a.card, target)
      if not ok then return nil, "目标不合法：" .. tostring(why) end
    end
    return { card = a.card, target = target }, nil
  end

  if kind == "card" then
    local a = picked[1]
    if not a.card then return nil, "动作缺少卡牌" end
    return a.card, nil
  end

  if kind == "discard" then
    local out = {}
    for _, a in ipairs(picked) do
      if not a.card then return nil, "动作缺少卡牌" end
      -- 重复选同一张：弃牌数会对不上，直接拒绝
      for _, c in ipairs(out) do
        if c == a.card then return nil, "重复选择了同一张牌" end
      end
      out[#out + 1] = a.card
    end
    return out, nil
  end

  if kind == "choose" then
    return picked[1].card, nil
  end

  if kind == "invoke" or kind == "choice" then
    return picked[1].value, nil
  end

  return nil, "未知动作类型：" .. tostring(kind)
end

return Parse
