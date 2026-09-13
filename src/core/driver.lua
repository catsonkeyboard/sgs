-- 驱动器：把房间的 pending 请求路由给 AI 或（UI 等待的）人类玩家
-- 这是协程循环与外部世界（UI/网络）之间的唯一桥梁。
local class = require "src.class"

local Driver = class("Driver")

function Driver:init(room, ai_respond)
  self.room = room
  self.ai_respond = ai_respond -- function(req, room) -> response
end

-- 推进直到：等待人类响应（return "human"）、游戏结束（return "over"）
function Driver:advance()
  while self.room.pending and not self.room.game_over do
    local req = self.room.pending
    if req.player.is_human then
      return "human"
    end
    local resp = self.ai_respond(req, self.room)
    self.room:step(resp)
  end
  return "over"
end

return Driver
