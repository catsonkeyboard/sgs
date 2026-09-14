-- AI 提示词构造：把「观察 + 候选动作」编成 LLM 的输入
--
-- 两条原则：
--   1. **只描述、不代劳** —— 规则判断已经由 actions.lua 用引擎算过了，
--      提示词里不再重复教「距离怎么算」，只给结论（候选里已带距离）。
--   2. **输出格式要窄** —— 只要一个 JSON 里的编号，越窄解析越稳。
--      实践上 LLM 最爱犯的错是加 markdown 代码块或多余解释，
--      所以要求写死在 system 里，解析侧也做了兜底（见 parse.lua）。
local Json = require "src.core.json"
local View = require "src.core.ai.view"

local Prompt = {}

Prompt.SYSTEM = [[你是三国杀标准身份局的玩家，由 AI 驱动。你完全自主决策，没有规则脚本替你兜底。

规则要点（合法性已由系统保证，你只需在给定选项里挑）：
- 身份：主公与忠臣要消灭反贼和内奸；反贼要杀主公；内奸要先清场再单挑主公。未亮明的身份只能靠行为推断。
- 每个回合有判定、摸牌、出牌、弃牌四个阶段；出牌阶段默认只能用一张【杀】（【诸葛连弩】或特定技能除外）。
- 攻击范围默认 1，武器可扩大；距离按座位数计算，进攻马 -1、防御马 +1。
- 体力降到 0 进入濒死，需有人出【桃】救援，否则阵亡。
- 弃牌阶段手牌数不得超过当前体力值。

【你要像真人一样思考】
1. 推算身份：谁在帮谁？谁打主公、谁保主公、谁在拱火？未亮身份的人要根据他的每一个动作修正判断。
   用你自己的决策史回看：某人前几轮做过什么、你当时怎么判断的。
2. 因人施策：对手的技能决定你怎么打他——对【空城】的诸葛亮要留着牌再打，对有【反馈】的司马懿要少用锦囊，
   对【奸雄】的曹操别把关键牌当伤害牌送给他。**先看技能，再决定出什么牌**。
3. 算得失：这张牌现在值不值得用？留着能不能换更大的收益？残血的人该不该救（他可能是敌人）？
4. 记住教训：你的决策史里有你自己写下的理由，如果之前判断错了，现在改。

你的任务：在给定的合法动作中选择最优的一个，输出它的编号。]]

local function dumpState(view)
  local me = view.me
  local lines = {}
  lines[#lines + 1] = string.format("第 %d 轮，当前阶段：%s，存活 %d 人，牌堆剩 %d 张",
    view.turn, me.phase or "?", view.alive_count, view.draw_pile)

  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("【你】%s（%s）身份：%s 体力 %d/%d 攻击范围 %d 技能：%s",
    me.name, me.general, me.role, me.hp, me.max_hp, me.attack_range,
    (#(me.skills or {}) > 0) and table.concat(me.skills, "、") or "无")
  if #me.hand > 0 then
    local parts = {}
    for i, c in ipairs(me.hand) do
      parts[#parts + 1] = string.format("%d)%s%s-%s", i, c.suit, c.number, c.zh)
    end
    lines[#lines + 1] = "  手牌：" .. table.concat(parts, " ")
  else
    lines[#lines + 1] = "  手牌：无"
  end
  for _, e in ipairs(me.equips or {}) do
    lines[#lines + 1] = string.format("  %s：%s", e.slot_zh, e.card.zh)
  end
  for _, j in ipairs(me.judges or {}) do
    lines[#lines + 1] = string.format("  判定区：%s", j.zh)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "【其他角色】"
  for _, o in ipairs(view.others) do
    local eq = {}
    for _, e in ipairs(o.equips or {}) do eq[#eq + 1] = e.card.zh end
    local jd = {}
    for _, j in ipairs(o.judges or {}) do jd[#jd + 1] = j.zh end
    lines[#lines + 1] = string.format("  座位%d %s（%s）%s 体力 %d/%d 手牌 %d 张 距离 %d%s%s%s",
      o.seat, o.name, o.general, o.role, o.hp, o.max_hp, o.hand_count, o.distance,
      o.alive and "" or " [已阵亡]",
      (#eq > 0) and (" 装备：" .. table.concat(eq, "、")) or "",
      (#jd > 0) and (" 判定区：" .. table.concat(jd, "、")) or "")
  end

  if #(view.log or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "【最近战况】"
    for _, l in ipairs(view.log) do
      lines[#lines + 1] = "  " .. l
    end
  end
  return table.concat(lines, "\n")
end

local function dumpActions(req, actions)
  local lines = {}
  local r = View.requestBrief(req)
  lines[#lines + 1] = "【现在需要你决定】" .. (r and r.ask or "做出选择")
  if r and r.prompt then lines[#lines + 1] = "（" .. r.prompt .. "）" end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "【合法动作】只能从中选择："
  for _, a in ipairs(actions) do
    lines[#lines + 1] = string.format("  %d. %s", a.id, a.desc)
  end
  return table.concat(lines, "\n")
end

local FORMAT = [[
【输出格式】只输出一行 JSON，不要 markdown 代码块，不要任何额外文字：
{"action": <编号>, "reason": "<一句话理由，中文，20 字以内>"}
需要选择多张牌时（如弃牌）改用：
{"actions": [<编号>, <编号>], "reason": "..."}

可选字段（**有新的身份判断时才写**，别每次都写）：
"beliefs": {"座位名或玩家名": "主公|忠臣|反贼|内奸|未知", ...}
"note": "<你想长期记住的一句话观察，100 字内>"]]

-- 返回 {system=, user=}，直接可塞进对话接口
function Prompt.build(room, req, actions, opts)
  opts = opts or {}
  local view = View.build(room, req, opts)
  local parts = { dumpState(view) }

  -- 决策史放在观察之后、选项之前：先看自己走过的路，再看现在的处境，
  -- 最后才是选择。顺序反过来会让模型先锚定选项、再找理由。
  if opts.memory then
    parts[#parts + 1] = ""
    parts[#parts + 1] = opts.memory:render(opts.nameOf)
  end

  -- 重试时把上一次为什么被拒说清楚，模型才有可能自己纠正
  if opts.retry_hint then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "【上一次的输出被拒绝】" .. opts.retry_hint
  end

  parts[#parts + 1] = ""
  parts[#parts + 1] = dumpActions(req, actions)
  parts[#parts + 1] = ""
  parts[#parts + 1] = FORMAT

  return {
    system = Prompt.SYSTEM,
    user = table.concat(parts, "\n"),
    view = view,      -- 便于测试断言与调试
    actions = actions,
  }
end

-- 调试用：把一次决策的完整输入打出来
function Prompt.debugText(room, req, actions, opts)
  local p = Prompt.build(room, req, actions, opts)
  return "=== SYSTEM ===\n" .. p.system .. "\n\n=== USER ===\n" .. p.user
end

Prompt.Json = Json

return Prompt
