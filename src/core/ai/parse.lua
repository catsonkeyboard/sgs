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

-- 从右往左找**最后一个**平衡的 JSON 对象。推理模型（glm-5 等走 chat
-- 协议）的推理文本里常出现中间草稿 JSON，最终答案在末尾——
-- extractJson 取第一个会拿错，这里从最后一个 } 往前反向配平尝试。
local function extractLastJson(raw)
  if type(raw) ~= "string" then return nil end
  local s = raw:gsub("```%w*", "")
  -- 收集全部 "}" 的位置，从最右边的开始反向配平
  local closes = {}
  local k = 1
  while true do
    local f = s:find("}", k, true)
    if not f then break end
    closes[#closes + 1] = f
    k = f + 1
  end
  for ci = #closes, 1, -1 do
    local endp = closes[ci]
    local depth, i = 1, endp - 1
    local in_str, esc = false, false
    while i >= 1 do
      local c = s:sub(i, i)
      if in_str then
        if esc then esc = false
        elseif c == "\\" then esc = true
        elseif c == '"' then in_str = false end
      elseif c == '"' then in_str = true
      elseif c == "}" then depth = depth + 1
      elseif c == "{" then
        depth = depth - 1
        if depth == 0 then break end
      end
      i = i - 1
    end
    if i >= 1 and depth == 0 then
      local obj = Json.decode(s:sub(i, endp))
      if type(obj) == "table" then return obj end
    end
  end
  return nil
end
Parse.extractLastJson = extractLastJson

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
  askForGuanxing = 1,
}

-- 主入口：raw 是 LLM 原始字符串，actions 是 Actions.enumerate 的结果
-- 返回 (响应, nil) 或 (nil, 错误原因)
function Parse.response(raw, req, room, actions)
  local me = req.player
  local data = extractJson(raw)
  local ids = data and normalizeIds(data)
  -- 首个 JSON 不可用（整个没有 JSON，或里面没有 action 字段）时，
  -- 从最后一个 JSON 对象再试一次——推理模型的中间草稿 JSON 会把
  -- extractJson 带偏，最终答案往往在文本末尾
  if not ids then
    local last = extractLastJson(raw)
    if last and last ~= data then
      data = last
      ids = normalizeIds(data)
    end
  end
  if not ids then
    if type(data) ~= "table" then return nil, "输出不是合法 JSON" end
    return nil, "缺少 action/actions 字段"
  end

  local picked = {}
  for _, id in ipairs(ids) do
    local a = type(id) == "number" and actions[id] or nil
    if not a then return nil, string.format("动作编号越界: %s", tostring(id)) end
    picked[#picked + 1] = a
  end

  -- 数量校验：弃牌要正好 n 张（any 模式如【制衡】允许 0..n 张），
  -- 其余请求只能选一个
  if req.type == "askForDiscard" then
    local want_n = req.n or 0
    if req.any then
      if #picked > want_n then
        return nil, string.format("弃牌数量超限：至多 %d 张，给了 %d 个", want_n, #picked)
      end
    elseif #picked ~= want_n then
      return nil, string.format("弃牌数量不符：需要 %d 张，给了 %d 个", want_n, #picked)
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

  -- 模型可选回传的「元信息」：身份判断与长期观察。
  -- 它们不影响这一步的合法性，解析失败也不该让整步作废，所以不做校验，
  -- 原样交给 Agent 去过滤（见 memory.lua 的 updateBeliefs）。
  local extra = {
    beliefs = type(data.beliefs) == "table" and data.beliefs or nil,
    note = type(data.note) == "string" and data.note or nil,
    reason = type(data.reason) == "string" and data.reason or nil,
  }

  if kind == "pass" then return nil, nil, extra end

  if kind == "use" then
    local a = picked[1]
    if not a.card then return nil, "动作缺少卡牌" end
    local target = playerBySeat(room, a.target_seat)
    if not target then return nil, "目标座位不存在" end
    if target ~= me then
      local ok, why = room:canUseCardOn(me, a.card, target)
      if not ok then return nil, "目标不合法：" .. tostring(why) end
    end
    extra.target_name = target.name
    return { card = a.card, target = target }, nil, extra
  end

  if kind == "card" then
    local a = picked[1]
    if not a.card then return nil, "动作缺少卡牌" end
    return a.card, nil, extra
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
    return out, nil, extra
  end

  if kind == "choose" then
    return picked[1].card, nil, extra
  end

  if kind == "invoke" or kind == "choice" then
    return picked[1].value, nil, extra
  end

  -- 观星：直接把候选里预构造的 up/down 顺序交给引擎
  -- （room.lua 对非表响应的约定是保持原序，这里的表一定合法：
  -- 元素就是刚从牌堆顶取出的那几张牌，只是顺序与顶底分配不同）
  if kind == "guanxing" then
    local a = picked[1]
    return { up = a.up, down = a.down }, nil, extra
  end

  return nil, "未知动作类型：" .. tostring(kind)
end

return Parse
