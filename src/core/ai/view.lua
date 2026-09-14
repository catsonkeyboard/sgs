-- AI 观察层：把房间状态压成「当前行动者视角下可知」的信息
--
-- **信息隐藏是硬要求，不是可选优化**：AI 只能看到自己的手牌与场上公开信息。
-- 别人的手牌只给张数，身份只给已亮明的（主公，或阵亡翻开的）。
-- 少了这层过滤，AI 就是开图作弊——身份局里玩家一眼看得出来，
-- 而且你调试时也搞不清 AI 到底是「推理出来的」还是「看见的」。
--
-- 纯 Lua，零 love 依赖（core/ 的硬规矩），因此可 headless 测试。
local Player = require "src.core.player"

local View = {}

-- 花色与身份的中文名（core/generals.lua 里的技能名已是中文，这里对齐风格）
View.SUIT_ZH = { [0] = "无", [1] = "黑桃", [2] = "红桃", [3] = "梅花", [4] = "方块" }
View.ROLE_ZH = { lord = "主公", loyalist = "忠臣", rebel = "反贼", renegade = "内奸" }

local SLOT_ZH = {
  weapon = "武器", armor = "防具",
  offensive_horse = "进攻马", defensive_horse = "防御马",
}

-- 牌的简要信息。id 是给 AI 指引用哪张牌的句柄（解析时按 id 找回真实对象）。
local function cardBrief(c)
  if not c then return nil end
  return {
    id = c.id,
    name = c.name,
    zh = c:zhName(),
    suit = View.SUIT_ZH[c.suit] or "?",
    number = c.number,
  }
end
View.cardBrief = cardBrief

local function equipsOf(p)
  local out = {}
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    local c = p.equips[slot]
    if c then
      out[#out + 1] = { slot = slot, slot_zh = SLOT_ZH[slot] or slot, card = cardBrief(c) }
    end
  end
  return out
end

local function judgesOf(p)
  local out = {}
  for _, c in ipairs(p.judges) do out[#out + 1] = cardBrief(c) end
  return out
end

-- 技能名（去重）。internal 的子技能（名字带「·」）是实现细节，不给 AI 看，
-- 免得【仁德·记录】这类记账技能占满提示词。
local function skillsOf(p)
  local out, seen = {}, {}
  local function add(list)
    for _, s in ipairs(list or {}) do
      local n = s.zh or s.name
      if type(n) == "string" and not seen[n] and not n:find("·") then
        seen[n] = true
        out[#out + 1] = n
      end
    end
  end
  add(p.general and p.general.skills)
  add(p.extra_skills)
  return out
end

-- 别人/自己的公开部分。reveal_role 只对自己（我当然知道我是谁）成立。
local function publicOf(p, me, room, reveal_role)
  return {
    seat = p.seat,
    name = p.name,
    general = (p.general and p.general.name) or "?",
    kingdom = p.kingdom,
    hp = p.hp,
    max_hp = p.max_hp,
    alive = p.alive,
    hand_count = #p.hand,
    equips = equipsOf(p),
    judges = judgesOf(p),
    chained = p.chained,
    role = (reveal_role or p.role_revealed) and (View.ROLE_ZH[p.role] or p.role) or "未知",
    distance = room:distance(me, p),
  }
end

-- 最近 n 条对局日志。AI 需要知道「刚才发生了什么」才能做时序推理，
-- 但全量日志太长，只取尾部。
local function recentLog(room, n)
  local lines = room.loglines or {}
  local out = {}
  for i = math.max(1, #lines - n + 1), #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

-- 把 coroutine.yield 出来的请求翻译成人话。req 里带的对象（玩家/牌）
-- 不能直接进 JSON，统一换成名字与座位号。
function View.requestBrief(req)
  if not req then return nil end
  local r = { type = req.type }
  if req.type == "askForCard" then
    r.ask = string.format("需要打出【%s】", req.card_name or "?")
    if req.prompt then r.prompt = req.prompt end
    if req.dying then r.dying = req.dying.name end
    if req.ask_from then r.from = req.ask_from.name end
    if req.ask_target then r.target = req.ask_target.name end
    if req.lord_request then r.lord_request = req.lord_request.name end
  elseif req.type == "askForDiscard" then
    r.ask = string.format("需要弃掉 %d 张牌", req.n or 0)
    r.n = req.n or 0
  elseif req.type == "askForChooseCard" then
    r.ask = "需要从展示的牌中选一张"
    if req.prompt then r.prompt = req.prompt end
  elseif req.type == "askForDiscardFrom" then
    r.ask = string.format("需要弃掉 %s 的一张牌", req.target and req.target.name or "目标")
  elseif req.type == "askForSkillInvoke" then
    r.ask = string.format("是否发动【%s】", tostring(req.skill))
  elseif req.type == "askForChoice" then
    r.ask = "需要做出选择"
  elseif req.type == "askForGuanxing" then
    r.ask = "可以重排牌堆顶的牌"
  elseif req.type == "askForUseCard" then
    r.ask = "出牌阶段：可以使用一张牌，或结束出牌"
  end
  return r
end

-- 构造观察。返回的都是纯数据（可直接 JSON 序列化）。
function View.build(room, req, opts)
  opts = opts or {}
  local me = req.player
  local others = {}
  for _, p in ipairs(room.players) do
    if p ~= me then
      others[#others + 1] = publicOf(p, me, room, false)
    end
  end

  local self_info = publicOf(me, me, room, true)
  self_info.hand = {}
  for _, c in ipairs(me.hand) do
    self_info.hand[#self_info.hand + 1] = cardBrief(c)
  end
  self_info.skills = skillsOf(me)
  self_info.attack_range = room:attackRangeOf(me)
  self_info.phase = me.phase

  return {
    turn = room.turn_count,
    identity_mode = room.identity_mode and true or false,
    alive_count = #room:alivePlayers(),
    draw_pile = #room.drawPile,
    discard_pile = #room.discardPile,
    me = self_info,
    others = others,
    log = recentLog(room, opts.log_lines or 12),
    request = View.requestBrief(req),
  }
end

return View
