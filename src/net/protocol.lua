-- 网络协议：JSON 文本帧，一行一条（\n 结尾）
--
-- 设计取舍：
--   1) 用 TCP（LuaSocket）而非 UDP —— 回合制卡牌游戏，可靠性优先于延迟。
--   2) 帧格式是「一行一个 JSON」，简单、好调试（telnet 都能看）。
--   3) 消息体只放**可序列化的数据**（id / 字符串 / 数字 / 布尔 / 表），
--      绝不传 Card / Player 对象 —— 对端是另一个进程，对象引用没有意义。
--
-- 消息一览：
--   C→S  hello{name}                 加入并报名
--        ready{ready}                准备/取消准备
--        resp{id, card?, cards?, target?, value?}   应答某个请求
--        bye{}
--   S→C  welcome{seat, seats, count} 分配座位
--        seats{seats}                座位表变化
--        start{seed}                 开局
--        req{id, type, player, ...}  请求某人应答（等待 resp）
--        log{lines}                  日志增量
--        state{...}                  局面快照
--        over{winner}                结束
local Json = require "src.core.json"

local Protocol = {}

-- 一行一帧
function Protocol.encode(msg)
  return Json.encode(msg) .. "\n"
end

function Protocol.decode(line)
  if not line or line == "" then return nil end
  local ok, msg = pcall(Json.decode, line)
  if not ok or type(msg) ~= "table" then return nil end
  return msg
end

-- 从 buffer 里切出完整帧；返回 (msg, remaining)
function Protocol.takeFrame(buf)
  local i = string.find(buf, "\n", 1, true)
  if not i then return nil, buf end
  local line = string.sub(buf, 1, i - 1)
  local msg = Protocol.decode(line)
  return msg, string.sub(buf, i + 1)
end

-- 把待发送的表转成「可序列化」的形式：剥掉 Card/Player 等对象引用。
-- 请求里可能带 cards（Card 对象数组）——客户端只需要能指回来的索引，
-- 因此统一转成「名字 + id + 花色 + 点数」的普通表。
function Protocol.slimCard(c)
  if type(c) ~= "table" then return c end
  return {
    id = c.id, name = c.name, suit = c.suit, number = c.number,
    zh = c.zhName and c:zhName() or nil,
  }
end

function Protocol.slimCards(list)
  local out = {}
  for _, c in ipairs(list or {}) do table.insert(out, Protocol.slimCard(c)) end
  return out
end

-- 把引擎的 pending 请求整理成可下发的消息
function Protocol.makeRequest(id, req, seatOf)
  local msg = {
    type = "req",
    id = id,
    req = req.type,
    seat = seatOf and seatOf(req.player) or nil,
    player = req.player and req.player.name or nil,
  }
  if req.card_name then msg.card_name = req.card_name end
  if req.n then msg.n = req.n end
  if req.cards then msg.cards = Protocol.slimCards(req.cards) end
  if req.choices then msg.choices = req.choices end -- 选项（玩家名/花色，字符串可直接序列化）
  if req.prompt then msg.prompt = req.prompt end
  if req.type == "askForSkillInvoke" then msg.skill = req.skill end
  -- 拆牌类：把可选的公开牌（装备/判定区）与手牌张数一并下发，
  -- 客户端据此渲染「拆装备 / 随机拆手牌」选项（应答时回传 card_id，
  -- 服务端在 target 的三个区域里按 id 找回对象）
  if req.type == "askForDiscardFrom" then
    msg.equip_judges = Protocol.slimCards(req.equip_judges)
    msg.hand_count = req.hand_count
    if req.hand_only then msg.hand_only = true end
  end
  -- 弃牌请求可携带本人装备候选（制衡 / 贯石斧），响应统一回传 card_ids；
  -- any 仅表示允许 0..n 张，普通技能代价仍须恰好 n 张。
  if req.type == "askForDiscard" then
    if req.any then msg.any = true end
    if req.include_equips then msg.include_equips = true end
  end
  -- 选牌类：允许不选（【顺手牵羊】不选则随机拿一张手牌）
  if req.allow_pass then msg.allow_pass = true end
  -- msg.hand 由 Host 单独补（只发给本人）
  return msg
end

return Protocol
