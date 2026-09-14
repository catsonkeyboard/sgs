-- AI 动作枚举：把「当前请求下能做什么」穷举成带编号的候选列表
--
-- **这是整套 AI 的地基**：LLM 不做自由生成，只在候选里挑编号。
-- 好处有三：
--   1. 结构上不可能产生非法动作（超出距离、超次数、鸡肋牌、不存在的目标）；
--   2. 提示词短、输出短、解析简单；
--   3. 规则判断全部复用引擎现成的 canUseCardOn / maxCards / slashLimit，
--      AI 与 BOT、人类玩家走同一套校验，不会出现「AI 能出、玩家不能出」。
--
-- 动作表里带的是**句柄**（card_id / target_seat / skill），不是直接可执行的
-- 响应；真正映射成 Card/Player 对象在 parse.lua 里做，且映射前会重新校验。
local Cards = require "src.core.cards"
local Card = require "src.core.card"

local Actions = {}

-- 常用转化目标（按性价比排序）。这只是**兜底清单**：
-- 真正要枚举的是「这个武将身上所有转化技能能变出什么」，
-- 光看固定清单会让【武圣】以外的技能（DIY 扩展里的尤其多）在 AI 手里失灵。
Actions.CONVERT_TARGETS = {
  "dismantlement", "indulgence", "supply_shortage", "await_exhausted",
  "slash", "fire_attack", "snatch", "duel",
}

-- 该玩家所有转化技能能变出的牌名：技能自带 result_name 的直接取，
-- 加上兜底清单（动态转化技没有固定 result_name，只能靠清单覆盖）
function Actions.convertTargets(room, p)
  local out, seen = {}, {}
  local function add(n)
    if type(n) == "string" and n ~= "" and not seen[n] then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  for _, s in ipairs(room:skillsOf(p)) do
    if s.view_as and s.result_name then add(s.result_name) end
  end
  for _, n in ipairs(Actions.CONVERT_TARGETS) do add(n) end
  return out
end

local function isSlashName(n)
  return n == "slash" or n == "fire_slash" or n == "thunder_slash"
end

-- 该牌是否「可以主动使用」。target="none" 的是纯响应牌（闪/无懈可击）。
local function activelyUsable(p, c, def)
  if p:isJilei(c) then return false end
  if not def then return c.skill_card ~= nil end
  if def.target == "none" then return false end
  if c.name == "peach" and p.hp >= p.max_hp then return false end -- 满血吃桃没意义
  if c.name == "analeptic" and p.drunk then return false end       -- 一回合一次
  return true
end

-- 这张牌在出牌阶段能指定哪些目标。AOE 与自用牌统一以自己为代表目标
-- （引擎内部会扩散到全体），敌人牌则逐个用 canUseCardOn 过滤。
local function targetsFor(room, me, card, def)
  if not def then
    -- 技能牌（原版 SkillCard）：没有卡牌定义，目标规则由技能自己定。
    -- 这里退化为「对自己」或「第一个存活的其他人」，与 BOT 的处理一致。
    if card.skill_card and card.skill_card.target_fixed then return { me } end
    local first = nil
    for _, q in ipairs(room.players) do
      if q ~= me and q.alive then first = q break end
    end
    return first and { first } or {}
  end
  if def.target == "self" or def.target == "all" or def.target == "all_other" then
    return { me }
  end
  if def.target == "enemy" or def.delayed then
    local out = {}
    for _, q in ipairs(room.players) do
      if q ~= me and q.alive then
        if def.delayed and q:hasDelayed(card.name) then
          -- 判定区已有同名延时锦囊，不能再放
        elseif room:canUseCardOn(me, card, q) then
          out[#out + 1] = q
        end
      end
    end
    return out
  end
  return { me }
end

local function cardLabel(c)
  return string.format("%s%s-%s", c:suitString(), c.number, c:zhName())
end

-- ===== 各请求类型的候选构造 =====

-- 出牌阶段：手牌 + 转化技，每张牌 × 每个合法目标各成一个动作
local function forUseCard(req, room)
  local me = req.player
  local out = {}

  local function pushUse(card, target, via_skill)
    local label = via_skill and
      string.format("以【%s】当作【%s】", via_skill.zh or via_skill.name, card:zhName())
      or string.format("出【%s】", cardLabel(card))
    if target == me then
      out[#out + 1] = { kind = "use", desc = label, card = card, target_seat = me.seat }
    else
      out[#out + 1] = {
        kind = "use",
        desc = string.format("%s → %s（体力 %d/%d，手牌 %d 张，距离 %d）",
          label, target.name, target.hp, target.max_hp, #target.hand,
          room:distance(me, target)),
        card = card, target_seat = target.seat,
      }
    end
  end

  -- 实体手牌优先：编号靠前在提示词里更显眼，且同样效果下出真牌更省
  for _, c in ipairs(me.hand) do
    local def = Cards.get(c.name)
    if activelyUsable(me, c, def) then
      for _, t in ipairs(targetsFor(room, me, c, def)) do
        pushUse(c, t, nil)
      end
    end
  end

  -- 转化技：虚拟牌不在手牌里，把生成好的牌挂在动作上（与 BOT 同做法，
  -- 无副作用——view_as 只造对象，不进任何区域，因此不影响卡牌守恒）
  for _, want in ipairs(Actions.convertTargets(room, me)) do
    for _, item in ipairs(room:viewAsCandidates(me, want)) do
      if not me:isJilei(item.card) then
        local args = { item.card }
        if item.card2 then args[2] = item.card2 end
        local made = item.skill:view_as(args)
        if made then
          for _, t in ipairs(targetsFor(room, me, made, Cards.get(made.name))) do
            pushUse(made, t, item.skill)
          end
        end
      end
    end
  end

  out[#out + 1] = { kind = "pass", desc = "结束出牌" }
  return out
end

-- 要求打出指定牌：实体牌 + 转化技 + 放弃
local function forCard(req, room)
  local me = req.player
  local wanted = req.card_name
  local out = {}
  for _, c in ipairs(me.hand) do
    if c.name == wanted and not me:isJilei(c) then
      out[#out + 1] = { kind = "card", desc = string.format("打出【%s】", cardLabel(c)),
        card = c, card_id = c.id }
    end
  end
  for _, item in ipairs(room:viewAsCandidates(me, wanted)) do
    if not me:isJilei(item.card) then
      local made = item.skill:view_as({ item.card })
      if made then
        out[#out + 1] = {
          kind = "card",
          desc = string.format("以【%s】把手牌【%s】当作【%s】打出",
            item.skill.zh or item.skill.name, cardLabel(item.card), made:zhName()),
          card = made, card_id = item.card.id, skill = item.skill,
        }
      end
    end
  end
  out[#out + 1] = { kind = "pass", desc = "不打出" }
  return out
end

-- 弃牌：一张一个候选，AI 返回多个编号
local function forDiscard(req, room)
  local me = req.player
  local out = {}
  for _, c in ipairs(me.hand) do
    if not me:isJilei(c) then
      out[#out + 1] = { kind = "discard", desc = string.format("弃掉【%s】", cardLabel(c)),
        card = c, card_id = c.id }
    end
  end
  return out
end

-- 五谷丰登：从展示的牌里挑一张
local function forChooseCard(req)
  local out = {}
  for _, c in ipairs(req.cards or {}) do
    out[#out + 1] = { kind = "choose", desc = string.format("拿【%s】", cardLabel(c)),
      card = c, card_id = c.id }
  end
  return out
end

-- 过河拆桥：替对手挑一张弃掉
local function forDiscardFrom(req)
  local out = {}
  for _, c in ipairs((req.target and req.target.hand) or {}) do
    out[#out + 1] = { kind = "choose",
      desc = string.format("弃掉 %s 的【%s】", req.target.name, cardLabel(c)),
      card = c, card_id = c.id }
  end
  return out
end

local function forSkillInvoke(req)
  return {
    { kind = "invoke", value = true, desc = string.format("发动【%s】", tostring(req.skill)) },
    { kind = "invoke", value = false, desc = "不发动" },
  }
end

local function forChoice(req)
  local out = {}
  for _, v in ipairs(req.choices or {}) do
    out[#out + 1] = { kind = "choice", value = v, desc = tostring(v) }
  end
  return out
end

local BUILDERS = {
  askForUseCard = forUseCard,
  askForCard = forCard,
  askForDiscard = forDiscard,
  askForChooseCard = forChooseCard,
  askForDiscardFrom = forDiscardFrom,
  askForSkillInvoke = forSkillInvoke,
  askForChoice = forChoice,
}

-- 统一出口：返回带连续编号的候选列表（编号即 LLM 要输出的东西）
function Actions.enumerate(req, room)
  local builder = BUILDERS[req.type]
  local list = builder and builder(req, room) or {}
  for i, a in ipairs(list) do a.id = i end
  return list
end

-- 该请求是否值得问 LLM。响应牌（闪/桃/无懈）几乎无脑且延迟敏感，
-- 默认走 BOT：一次 LLM 往返 1~3 秒，每次被杀都等一下，对局会变得难以忍受。
Actions.LLM_WORTHY = {
  askForUseCard = true,    -- 出牌阶段：核心决策
  askForSkillInvoke = true,
  askForDiscard = true,
  askForChooseCard = true,
  askForDiscardFrom = true,
  askForChoice = true,
}

function Actions.worthAsking(req, opts)
  opts = opts or {}
  if opts.all_requests then return true end
  return Actions.LLM_WORTHY[req.type] == true
end

return Actions
