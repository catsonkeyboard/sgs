-- 驱动器：把房间的 pending 请求路由给 BOT 或（UI 等待的）人类玩家
-- 注意：BOT = 规则驱动的脚本对手；真正的 AI（LLM）是另一套响应源，
-- 将来接进来时同样挂在这里，与 BOT 是并列关系。
-- 这是协程循环与外部世界（UI/网络）之间的唯一桥梁。
local class = require "src.class"

local Driver = class("Driver")

function Driver:init(room, bot_respond)
  self.room = room
  self.bot_respond = bot_respond -- function(req, room) -> response
end

-- 推进直到：等待人类响应（return "human"）、游戏结束（return "over"）
function Driver:advance()
  while self.room.pending and not self.room.game_over do
    local req = self.room.pending
    if req.player.is_human then
      return "human"
    end
    local resp = self.bot_respond(req, self.room)
    self.room:step(resp)
  end
  return "over"
end

return Driver
