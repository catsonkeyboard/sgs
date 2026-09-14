-- 原版 QSanguosha 的 Room / ServerPlayer / Card API 别名
--
-- 设计原则：
--   1) **绝不无意覆盖引擎已有方法**。所有别名都通过下面的 define() 安装，
--      撞名会直接报错。起因：兼容层曾覆盖 Room:useCard / Player:hasEquip /
--      Room:throwCard，签名不同而引擎内部仍在按原签名调用 —— 表现为
--      「所有出牌静默失效、对局卡满 300 回合」，报错点离真因极远。
--   2) **不做 __index 兜底**。本引擎自己的拼写错误仍然立刻报错
--      （`_slashDamage` 那个 bug 就是靠报错才暴露的）。DIY 脚本调用到
--      尚未实现的方法时也照常报错，比悄悄返回 nil 更容易定位。
local Room = require "src.core.room"
local Player = require "src.core.player"
local Card = require "src.core.card"
local sk = require "src.core.skill"

local API = {}
local installed = false

local function define(cls, name, fn, override)
  if cls[name] ~= nil and not override then
    error(string.format(
      "[兼容层] 试图覆盖已存在的方法 %s（若确有意为之请传 override=true）", name), 2)
  end
  cls[name] = fn
end

-- ===== Card =====

-- view_as 调用期间由 sgs 兼容层注入当前选中牌，供 addSubcard(id) 还原
local current_subcards = {}
local function sgs_current() return current_subcards end

define(Card, "getId", function(self) return self.id end)
define(Card, "getEffectiveId", function(self) return self.id end)
define(Card, "getSuit", function(self) return self.suit end)
define(Card, "getNumber", function(self) return self.number end)
-- 原版 AI 脚本用这两个拼 Card_Parse 字符串，需要的是花色/点数的**名字**
define(Card, "getSuitString", function(self)
  return string.lower(self:suitString()) == "s" and "spade"
    or string.lower(self:suitString()) == "h" and "heart"
    or string.lower(self:suitString()) == "c" and "club"
    or string.lower(self:suitString()) == "d" and "diamond" or "no_suit"
end)
define(Card, "getNumberString", function(self)
  return ({ [1] = "A", [11] = "J", [12] = "Q", [13] = "K" })[self.number]
    or tostring(self.number)
end)
define(Card, "isBlack", function(self) return not self:isRed() end)
define(Card, "getTypeId", function(self) return self.ctype end)
define(Card, "objectName", function(self) return self.name end)
define(Card, "getClassName", function(self) return self.name end)
define(Card, "getSkillName", function(self) return self.skill_name end)
define(Card, "setSkillName", function(self, n)
  self.skill_name = n
  return self
end)
define(Card, "subcardsLength", function(self) return #(self.subcards or {}) end)
define(Card, "toString", function(self) return string.format("%s:%d", self.name, self.id) end)
-- 原版返回 QList，脚本会调 :length()，这里返回带 length/at 的壳
define(Card, "getSubcards", function(self)
  return API.list(self.subcards or {})
end)
define(Card, "sameSuitWith", function(self, other) return other and self.suit == other.suit end)

define(Card, "isKindOf", function(self, n)
  if not n then return false end
  n = string.lower(n)
  local alias = {
    basiccard = "basic", trickcard = "trick", equipcard = "equip",
    slash = "slash", jink = "dodge", peach = "peach", analeptic = "analeptic",
  }
  local mapped = alias[n] or n
  if mapped == "basic" then return self.ctype == Card.Type.Basic end
  if mapped == "trick" then return self.ctype == Card.Type.Trick end
  if mapped == "equip" then return self.ctype == Card.Type.Equip end
  if mapped == "slash" then
    return self.name == "slash" or self.name == "fire_slash" or self.name == "thunder_slash"
  end
  return self.name == mapped
end)

-- DIY 脚本典型写法：new_card:addSubcard(card:getId())
-- 传进来的是 id，必须还原成真正的 Card 对象，否则引擎无法把实体牌从手牌取走
define(Card, "addSubcard", function(self, x)
  self.subcards = self.subcards or {}
  if type(x) == "table" then
    table.insert(self.subcards, x)
    return self
  end
  for _, c in ipairs(sgs_current()) do
    if c.id == x then
      table.insert(self.subcards, c)
      return self
    end
  end
  return self
end)

function API.setCurrentSubcards(cards) current_subcards = cards or {} end

-- ===== 列表壳 =====
-- 原版 getSubcards() 返回 QList，脚本会写 :length() / :at() / :contains()
local List = {}
List.__index = List
function API.list(t)
  local l = setmetatable({ __items = t or {} }, List)
  return l
end
function List:length() return #self.__items end
function List:at(i) return self.__items[(i or 0) + 1] end
function List:first() return self.__items[1] end
function List:last() return self.__items[#self.__items] end
function List:isEmpty() return #self.__items == 0 end
function List:contains(x)
  for _, v in ipairs(self.__items) do if v == x then return true end end
  return false
end
function List:toTable() return self.__items end

-- ===== Skill =====

define(sk.Skill, "objectName", function(self) return self.name end)

-- ===== Player =====

define(Player, "objectName", function(self) return self.name end)
define(Player, "getName", function(self) return self.name end)
define(Player, "getGeneralName", function(self) return self.general and self.general.name or self.name end)
define(Player, "getHp", function(self) return self.hp end)
define(Player, "setHp", function(self, n) self.hp = n end)
define(Player, "getMaxHp", function(self) return self.max_hp end)
define(Player, "getLostHp", function(self) return self.max_hp - self.hp end)
define(Player, "isWounded", function(self) return self.hp < self.max_hp end)
define(Player, "isAlive", function(self) return self.alive end)
define(Player, "isDead", function(self) return not self.alive end)
define(Player, "getHandcardNum", function(self) return #self.hand end)
define(Player, "getHandcards", function(self) return self.hand end)
define(Player, "getCards", function(self, _place) return self.hand end)
define(Player, "isKongcheng", function(self) return #self.hand == 0 end)
define(Player, "getJudgingArea", function(self) return self.judges end)
define(Player, "getRole", function(self) return self.role end)
define(Player, "getKingdom", function(self) return self.kingdom end)
define(Player, "getSeat", function(self) return self.seat end)
define(Player, "getPhase", function(self) return self.phase end)
define(Player, "isLord", function(self) return self.role == "lord" end)
define(Player, "isMale", function(self) return not self.female end)
define(Player, "isFemale", function(self) return self.female == true end)
define(Player, "getOffensiveHorse", function(self) return self.equips.offensive_horse end)
define(Player, "getDefensiveHorse", function(self) return self.equips.defensive_horse end)
define(Player, "faceUp", function(self) return not self.turned_over end)
define(Player, "turnOver", function(self)
  self.turned_over = not self.turned_over
  return self.turned_over
end)

define(Player, "isNude", function(self)
  if #self.hand > 0 then return false end
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    if self.equips[slot] then return false end
  end
  return true
end)

define(Player, "getEquips", function(self)
  local out = {}
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    if self.equips[slot] then table.insert(out, self.equips[slot]) end
  end
  return out
end)

-- 注意：不能叫 hasEquip —— 引擎已有 Player:hasEquip(name)
define(Player, "hasAnyEquip", function(self) return #self:getEquips() > 0 end)

define(Player, "hasSkill", function(self, name)
  for _, s in ipairs((self.general and self.general.skills) or {}) do
    if s.name == name or s.zh == name then return true end
  end
  for _, s in ipairs(self.extra_skills or {}) do
    if s.name == name then return true end
  end
  return false
end)

-- 原版 mark / pile / flag 在本引擎里退化到玩家表上的稀疏表
define(Player, "getMark", function(self, k) return (self.marks or {})[k] or 0 end)
define(Player, "setMark", function(self, k, v)
  self.marks = self.marks or {}
  self.marks[k] = v
end)
define(Player, "addMark", function(self, k, v)
  self.marks = self.marks or {}
  self.marks[k] = (self.marks[k] or 0) + (v or 1)
end)
define(Player, "getPile", function(self, k)
  self.piles = self.piles or {}
  return self.piles[k] or {}
end)
define(Player, "addToPile", function(self, k, cards)
  self.piles = self.piles or {}
  self.piles[k] = self.piles[k] or {}
  for _, c in ipairs(cards or {}) do table.insert(self.piles[k], c) end
end)
define(Player, "hasFlag", function(self, f)
  return (self.flags or {})[f] == true
end)
define(Player, "setFlags", function(self, f)
  self.flags = self.flags or {}
  if not f then return end
  local neg = string.sub(f, 1, 1) == "-"
  self.flags[neg and string.sub(f, 2) or f] = not neg
end)
define(Player, "getMaxCards", function(self) return math.max(self.hp, 0) end)
-- 原版的「禁用/限制」概念（鸡肋、卡牌限制）本引擎未实现，一律放行
define(Player, "isProhibited", function() return false end)
define(Player, "isCardLimited", function() return false end)
define(Player, "isJilei", function() return false end)
define(Player, "canDiscard", function(_self, _who, _flags) return true end)
define(Player, "drawCards", function(self, n)
  local room = (require "src.compat.sgs").CurrentRoom
  if room then room:drawCards(self, n) end
end)

-- ===== Room =====
-- 覆盖同名方法前先留存原实现，否则别名会自我递归（栈溢出）
local engineLoseHp = Room.loseHp
local engineAskForCard = Room.askForCard
local engineAskForDiscard = Room.askForDiscard
local engineAskForUseCard = Room.askForUseCard
local engineUseCard = Room.useCard
local engineDamage = Room.damage

define(Room, "obtainCard", function(self, p, card) return self:obtain(p, card) end)
define(Room, "recover", function(self, p, n) return self:heal(p, n or 1) end)
define(Room, "getAlivePlayers", function(self) return self:alivePlayers() end)
define(Room, "getOtherPlayers", function(self, p) return self:otherAlivePlayers(p) end)
define(Room, "getCurrent", function(self) return self.players[self.current_seat] end)
define(Room, "getDrawPile", function(self) return self.drawPile end)
define(Room, "getDiscardPile", function(self) return self.discardPile end)
define(Room, "sortByActionOrder", function(_self, list) return list end)
define(Room, "setPlayerFlag", function(self, p, f) if p then p:setFlags(f) end end)
define(Room, "getPlayerMark", function(_self, p, k) return p and p:getMark(k) or 0 end)
define(Room, "setPlayerMark", function(_self, p, k, v) if p then p:setMark(k, v) end end)
define(Room, "addPlayerMark", function(_self, p, k, v) if p then p:addMark(k, v or 1) end end)
define(Room, "notifySkillInvoked", function() end)
define(Room, "broadcastSkillInvoke", function() end)
define(Room, "removePlayerDisableShow", function() end)
define(Room, "doAnimate", function() end)
define(Room, "sendLog", function(self, msg) self:log("%s", tostring(msg and msg.type or msg)) end)
-- 引擎已有 Room:askForSkillInvoke（人类会弹选择、AI 直接发动），
-- 这里委托过去，只是适配原版「传技能名字符串」的签名。
local engineAskForSkillInvoke = Room.askForSkillInvoke
define(Room, "askForSkillInvoke", function(self, p, name)
  return engineAskForSkillInvoke(self, p, name)
end, true)
-- 注意：不覆盖 askForNullification —— 引擎内部按 (use) 调用它，
-- 而原版签名不同，覆盖会让【无懈可击】彻底失效。

define(Room, "askForChoice", function(_self, _p, _skill, choices)
  if type(choices) ~= "string" then return nil end
  return string.match(choices, "([^+]+)") -- 取第一个选项，避免脚本卡在询问上
end)
define(Room, "askForSuit", function(self)
  local suits = { Card.Suit.Spade, Card.Suit.Heart, Card.Suit.Club, Card.Suit.Diamond }
  return suits[self:random(4)]
end)
define(Room, "askForPlayerChosen", function(_self, p, targets)
  for _, t in ipairs(targets or {}) do
    if t ~= p and t.alive then return t end
  end
  return nil
end)

-- 拼点：本引擎的 pindian 直接结算并返回胜负，这里补出原版 PindianStruct 的字段
define(Room, "askForPindian", function(self, a, b, reason)
  if not (a and b) or #a.hand == 0 or #b.hand == 0 then return nil end
  local ca, cb = a.hand[1], b.hand[1]
  local na, nb = ca.number, cb.number
  local success = self:pindian(a, b)
  return {
    success = success, from = a, to = b, reason = reason,
    from_card = ca, to_card = cb, from_number = na, to_number = nb,
  }
end)

-- 展示一张手牌（【缔盟】等会用到）
define(Room, "askForCardShow", function(_self, p, _requestor, _reason)
  if p and #p.hand > 0 then return p.hand[1] end
  return nil
end)

-- 从展示的若干张牌里挑一张（返回 id）
define(Room, "askForAG", function(_self, _p, ids, refusable)
  if not ids or #ids == 0 then return nil end
  if refusable and #ids == 1 then return nil end
  return ids[1]
end)
define(Room, "fillAG", function() end)
define(Room, "takeAG", function() end)
define(Room, "clearAG", function() end)
define(Room, "closeAG", function() end)

-- 分配若干张牌给其他角色（【遗计】类）。
-- 原版脚本惯用 `while room:askForYiji(...) do ... end`，
-- 因此这里**必须返回 false** 让循环结束，否则会无限循环。
define(Room, "askForYiji", function(self, p, ids, _reason)
  local to = nil
  for _, q in ipairs(self.players) do
    if q ~= p and q.alive then to = q break end
  end
  if not to then return false end
  for _, c in ipairs(ids or {}) do
    local card = c
    if type(c) == "number" then -- 传进来的是 id，回弃牌堆找
      for _, x in ipairs(self.discardPile) do
        if x.id == c then card = x break end
      end
    end
    if card and type(card) == "table" and card.name then
      -- 必须先从原区域摘出来再进手牌，否则同一张牌会被登记两次
      -- （牌可能在给出者手里，也可能在弃牌堆里）
      local removed = (to == card) and false or self:_removeCardEverywhere(card)
      if removed then table.insert(to.hand, card) end
    end
  end
  self:log("%s 将 %d 张牌交给 %s", p.name, #(ids or {}), to.name)
  return false
end)

define(Room, "askForSinglePeach", function(self, p, _dying)
  return self:askForCard(p, "peach", "濒死：需要使用一张【桃】")
end)

-- 请求对指定目标之一使用一张【杀】
define(Room, "askForUseSlashTo", function(_self, p, targets, _reason)
  local slash = nil
  for _, c in ipairs(p.hand or {}) do
    if c.name == "slash" or c.name == "fire_slash" or c.name == "thunder_slash" then
      slash = c
      break
    end
  end
  local to = nil
  for _, t in ipairs(targets or {}) do
    if t and t.alive then to = t break end
  end
  if not (slash and to) then return nil end
  return { card = slash, from = p, to = { to } }
end)

-- 【观星】类：让脚本重排牌堆顶。本引擎 AI 不调整，返回空表示维持原序
define(Room, "askForGuanxing", function() return {} end)

-- 交换/调整手牌：按用途退化为「挑出 n 张」
define(Room, "askForExchange", function(self, p, _reason, n, _m)
  return self:askForDiscard(p, n or 1)
end)
define(Room, "askForCardChosen", function(_self, _p, target)
  if not target then return nil end
  if #target.hand > 0 then return target.hand[1] end
  for _, slot in ipairs(Player.EQUIP_SLOTS) do
    if target.equips[slot] then return target.equips[slot] end
  end
  return nil
end)
define(Room, "setFixedDistance", function(_self, from, to, d)
  if not (from and to) then return end
  from.fixed_distance = from.fixed_distance or {}
  from.fixed_distance[to] = d
end)
define(Room, "killPlayer", function(self, p)
  if p and p.alive then self:_kill(p, nil) end
end)

-- 原版 room:getThread():trigger(event, room, player, data)
-- 本引擎的 trigger 就在 Room 上，这里套一层即可
define(Room, "getThread", function(self)
  return {
    trigger = function(_thread, event, _room, player, data)
      return self:trigger(event, player, data)
    end,
    delay = function() end,
  }
end)

-- room:moveCardTo(card, from, to, place, reason, silent)
define(Room, "moveCardTo", function(self, card, from, _to, _place, _reason, _silent)
  if from then from:takeCard(card) end
  -- 本引擎目前只有「弃牌堆」一个去处，其余落点一律按弃牌处理
  table.insert(self.discardPile, card)
end)

-- 从任意区域摘除一张牌（玩家手牌/装备/判定区、弃牌堆、牌堆），成功返回 true。
-- 卡片移动的通用前置：任何「移到别处」的操作都该以它为前提。
function Room:_removeCardEverywhere(card)
  for _, p in ipairs(self.players) do
    if p:takeCard(card) then return true end
    for _, s in ipairs(Player.EQUIP_SLOTS) do
      if p.equips[s] == card then
        p.equips[s] = nil
        return true
      end
    end
  end
  for _, pile in ipairs({ self.discardPile, self.drawPile }) do
    for i, c in ipairs(pile) do
      if c == card then
        table.remove(pile, i)
        return true
      end
    end
  end
  return false
end

-- ===== 常用辅助 =====
-- 注意：api.lua 被 sgs.lua 依赖，这里**不能** require sgs（会循环依赖），
-- 需要的小工具就在本地实现一份。
local function toNum(v)
  if type(v) == "number" then return v end
  return tonumber(v) or v
end

-- 原版 room:setPlayerProperty(player, "hp", value) 之类
define(Room, "setPlayerProperty", function(self, p, key, value)
  if not p then return end
  if key == "hp" then p.hp = toNum(value)
  elseif key == "max_hp" or key == "maxhp" then p.max_hp = toNum(value)
  elseif key == "phase" then p.phase = value
  elseif key == "role" then p.role = value
  elseif key == "kingdom" then p.kingdom = value
  elseif key == "chained" then p.chained = (value == true)
  elseif key == "turned" or key == "faceup" then p.turned_over = (value ~= true)
  else p[key] = value end
  if self.log then self:log("%s 的 %s 被设置为 %s", p.name, tostring(key), tostring(value)) end
end)

define(Room, "getCardPlace", function(self, id)
  for _, p in ipairs(self.players) do
    for _, c in ipairs(p.hand) do if c.id == id then return "hand" end end
    for _, s in ipairs(Player.EQUIP_SLOTS) do
      if p.equips[s] and p.equips[s].id == id then return "equip" end
    end
    for _, c in ipairs(p.judges) do if c.id == id then return "judge" end end
  end
  for _, c in ipairs(self.discardPile) do if c.id == id then return "discardPile" end end
  for _, c in ipairs(self.drawPile) do if c.id == id then return "drawPile" end end
  return "unknown"
end)

define(Room, "getCardOwner", function(self, id)
  for _, p in ipairs(self.players) do
    for _, c in ipairs(p.hand) do if c.id == id then return p end end
  end
  return nil
end)

define(Room, "setTag", function(self, k, v) self.tags = self.tags or {}; self.tags[k] = v end)
define(Room, "getTag", function(self, k) return (self.tags or {})[k] end)
define(Room, "removeTag", function(self, k) if self.tags then self.tags[k] = nil end end)

-- 技能增删：本引擎把技能挂在 general.skills / extra_skills 上
define(Room, "acquireSkill", function(self, p, name)
  if not (p and name) then return end
  p.extra_skills = p.extra_skills or {}
  for _, s in ipairs(p.extra_skills) do if s.name == name then return end end
  table.insert(p.extra_skills, { name = name, zh = name })
  self:log("%s 获得技能 %s", p.name, tostring(name))
end)
define(Room, "attachSkillToPlayer", function(self, p, name) self:acquireSkill(p, name) end)
define(Room, "detachSkillFromPlayer", function(self, p, name)
  if not (p and p.extra_skills) then return end
  for i, s in ipairs(p.extra_skills) do
    if s.name == name then table.remove(p.extra_skills, i) break end
  end
  self:log("%s 失去技能 %s", p.name, tostring(name))
end)

-- 纯表现层：本引擎无动画/灯箱，空实现即可
define(Room, "setEmotion", function() end)
define(Room, "doLightbox", function() end)
define(Room, "doSuperLightbox", function() end)
define(Room, "output", function(_self, msg) print(tostring(msg)) end)
define(Room, "writeToConsole", function(_self, msg) print(tostring(msg)) end)
define(Room, "notifyMoveCards", function() end)
define(Room, "updateStateItem", function() end)
define(Room, "showCard", function() end)
define(Room, "filterCards", function() end)
define(Room, "changeHero", function() end)
define(Room, "swapSeat", function() end)
define(Room, "playSkillEffect", function() end)

-- 同名覆盖：必须兼容引擎内部调用与原版脚本调用两种签名
--   引擎：  room:loseHp(p, n)
--   原版：  room:loseHp(p, n)
define(Room, "loseHp", function(self, p, n)
  return engineLoseHp(self, p, n or 1)
end, true)

--   引擎：  room:askForCard(player, card_name, prompt, extra)
--   原版：  room:askForCard(player, pattern, prompt, data, method, who, isRetrial)
-- 前三个参数一致；原版多传的后续参数在这里被忽略（引擎侧只认第 4 个 table 参数）
define(Room, "askForCard", function(self, p, pattern, prompt, extra)
  if type(extra) ~= "table" then extra = nil end
  return engineAskForCard(self, p, pattern, prompt, extra)
end, true)

--   引擎：  room:askForDiscard(player, n)
--   原版：  room:askForDiscard(player, reason, n, m, ...)
define(Room, "askForDiscard", function(self, p, a, b)
  local n = (type(a) == "number") and a or b -- a 是数字说明是引擎调用
  return engineAskForDiscard(self, p, n or 1)
end, true)

define(Room, "askForUseCard", function(self, p, _pattern, _prompt)
  return engineAskForUseCard(self, p)
end, true)

--   引擎：  room:useCard(from, card, target)
--   原版：  room:useCard(CardUseStruct)
define(Room, "useCard", function(self, a, b, c)
  if type(a) == "table" and a.to and a.card then
    return engineUseCard(self, a.from, a.card, a.to[1])
  end
  return engineUseCard(self, a, b, c)
end, true)

--   引擎：  room:damage(from, to, n, nature, card)
--   原版：  room:damage(DamageStruct)
-- 判定依据：DamageStruct 带 .to 且 .to 是玩家（有 max_hp）
define(Room, "damage", function(self, from, to, n, nature, card)
  if type(from) == "table" and from.to and from.to.max_hp then
    local d = from
    return engineDamage(self, d.from, d.to, d.damage or d.n or 1, d.nature, d.card)
  end
  return engineDamage(self, from, to, n, nature, card)
end, true)

function API.install()
  if installed then return true end
  installed = true
  return true
end

return API
