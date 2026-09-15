-- AI 记忆：让 LLM 看到自己走过的每一步与推理过的结论
--
-- **为什么必须有它**：无记忆时每次调用都是一次孤立的问答，AI 看不到
-- 「上一轮谁打了我」「我上次判断谁是反贼」，于是身份推理无从积累，
-- 只能靠提示词里那几行近期日志拍脑袋。有了记忆，它才能像人一样：
-- 第 3 轮怀疑 P2 是反贼 → 第 5 轮发现 P2 救了主公 → 修正判断。
--
-- 结构：
--   steps    每一步的决策记录（谁问的、选了什么、为什么）
--   beliefs  对各自身份的最新判断（AI 自己写的，可随时推翻）
--   notes    AI 自己维护的长期观察（可选，由它决定要不要写）
--
-- 预算控制：完整历史会无限增长，超过 max_steps 后把最早的部分
-- 折叠成一行统计摘要（「更早：出杀×5、出闪×3…」），细节不丢全局。
local Memory = {}
local class = require "src.class"

local Mem = class("Mem")

function Mem:init(opts)
  opts = opts or {}
  self.seat = opts.seat                 -- 属于哪个座位（调试用）
  self.max_steps = opts.max_steps or 60 -- 超过这个步数就把最早的折叠掉
  self.steps = {}                       -- {turn=, stage=, ask=, choice=, reason=}
  self.folded = {}                      -- 已折叠步骤的分类计数
  self.folded_count = 0
  self.beliefs = {}                     -- {["P2"]="反贼", ...}
  self.belief_log = {}                  -- 判断变化时间线 {turn,name,from,to,reason}
  self.max_belief_log = 60              -- 时间线上限（防无限增长）
  self.notes = opts.notes or ""         -- AI 自己写的长期观察
  self.total = 0
  self.rejected = {}                    -- 被拒绝的输出，供调试
end

-- 记录一步。stage 是给人看的短标签（出牌 / 响应 / 弃牌 / 技能 / 选择）
function Mem:record(entry)
  entry = entry or {}
  self.total = self.total + 1
  table.insert(self.steps, {
    turn = entry.turn,
    stage = entry.stage or "?",
    ask = entry.ask or "",
    choice = entry.choice or "",
    reason = entry.reason or "",
  })
  while #self.steps > self.max_steps do
    local old = table.remove(self.steps, 1)
    self.folded_count = self.folded_count + 1
    local key = old.stage
    self.folded[key] = (self.folded[key] or 0) + 1
  end
end

-- 更新身份判断。只接受已知座位，值做长度限制，避免模型输出垃圾把提示词撑爆。
-- 返回本次发生变化的记录列表 { {name=, from=, to=} }（无变化为空表），
-- 同时追加进 belief_log 供 UI 展示「猜测过程」——只有最新标签的话，
-- 玩家永远看不到 AI 是怎么一步步改判的。
local VALID_LABEL = {
  ["主公"] = true, ["忠臣"] = true, ["反贼"] = true, ["内奸"] = true,
  ["未知"] = true, ["不确定"] = true,
}

function Mem:updateBeliefs(b, nameOf, meta)
  if type(b) ~= "table" then return {} end
  local changes = {}
  for key, val in pairs(b) do
    local name = tostring(key)
    -- 允许模型用座位号（"2" / "P2" / "座位2"）或玩家名指代。
    -- 注意不能写成 `nameOf(name) or name`：那样解析不出时会退化成
    -- 拿原始 key 当玩家名，凭空造出一个不存在的角色。
    local target = name
    if nameOf then
      target = nameOf(name)
    end
    local label = tostring(val):gsub("%s", "")
    -- 常见变体归一
    label = label:gsub("主公技", "主公")
    local hit = nil
    for k in pairs(VALID_LABEL) do
      if label:find(k, 1, true) then hit = k break end
    end
    if hit and target then
      if self.beliefs[target] ~= hit then
        local from = self.beliefs[target] or "未知"
        self.beliefs[target] = hit
        changes[#changes + 1] = { name = target, from = from, to = hit }
        self.belief_log[#self.belief_log + 1] = {
          turn = meta and meta.turn, name = target,
          from = from, to = hit, reason = meta and meta.reason or "",
        }
        while #self.belief_log > self.max_belief_log do
          table.remove(self.belief_log, 1)
        end
      end
    end
  end
  return changes
end

-- 猜测变化时间线（旧的在前），最多保留 max_belief_log 条
function Mem:beliefTimeline()
  return self.belief_log
end

function Mem:setNotes(text)
  if type(text) == "string" and #text > 0 and #text <= 300 then
    self.notes = text
  end
end

-- 渲染成提示词里的一段。**格式要紧凑**：这段每步都会随请求发出去，
-- 一个字符乘上几百步就是 token 账单。
function Mem:render(nameOf)
  local out = {}
  if self.total == 0 then
    -- 可以没有历史，但**不能因此吞掉身份判断**：模型可能第一步就给出了
    -- 对别人的判断，那正是后面决策的依据
    out[#out + 1] = "【你的决策史】这是你的第一步，还没有历史。"
  else
    out[#out + 1] = string.format("【你的决策史】共 %d 步%s", self.total,
      self.folded_count > 0 and string.format("（最早的 %d 步已折叠）", self.folded_count) or "")

    if self.folded_count > 0 then
      local parts = {}
      for stage, n in pairs(self.folded) do
        parts[#parts + 1] = string.format("%s×%d", stage, n)
      end
      table.sort(parts)
      out[#out + 1] = "  …更早：" .. table.concat(parts, "、")
    end

    for _, s in ipairs(self.steps) do
      out[#out + 1] = string.format("  第%s轮 %s：%s%s",
        tostring(s.turn or "?"), s.stage, s.choice,
        (s.reason ~= "" and ("｜" .. s.reason)) or "")
    end
  end

  if self.notes ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = "【你自己的长期观察】" .. self.notes
  end

  local keys = {}
  for k in pairs(self.beliefs) do keys[#keys + 1] = k end
  if #keys > 0 then
    table.sort(keys)
    out[#out + 1] = ""
    out[#out + 1] = "【你上次对各自身份的判断】（可随时推翻重判）"
    for _, k in ipairs(keys) do
      out[#out + 1] = string.format("  %s：%s", k, self.beliefs[k])
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "【Identity 判断】你还没有对任何人的身份做出判断。如果你有推论，在 beliefs 字段里给出。"
  end
  return table.concat(out, "\n")
end

function Mem:stepCount() return #self.steps end

-- 某个请求类型（stage）历史上出现过几次，AI 可用来自我校准
function Mem:stats()
  local s = {}
  for _, step in ipairs(self.steps) do
    s[step.stage] = (s[step.stage] or 0) + 1
  end
  return s
end

Memory.Mem = Mem
Memory.create = function(opts) return Mem.create(opts or {}) end

return Memory
