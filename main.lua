-- 入口：--test 无头跑测试；--soak 大批量压力测试；否则进入菜单 → 牌桌
local is_test, autostart, is_soak, is_net, is_serve = false, false, false, false, false
for _, a in ipairs(arg or {}) do
  if a == "--test" then is_test = true end
  if a == "--soak" then is_soak = true end
  if a == "--net" then is_net = true end
  if a == "--serve" then is_serve = true end
  if a == "--autostart" then autostart = true end
end

local current_scene = nil

local startGame, backToMenu

startGame = function(mode, size)
  local RoomScene = require "src.ui.scene_room"
  current_scene = RoomScene.create(backToMenu, mode, size)
end

backToMenu = function()
  local MenuScene = require "src.ui.scene_menu"
  current_scene = MenuScene.create(startGame)
end

function love.load()
  -- --serve：以服务端模式启动（阶段 D，见 src/net/server.lua）
  if is_serve then
    local ok, err = pcall(function()
      require("src.net.server").main()
    end)
    if not ok then print("服务端异常: " .. tostring(err)) end
    love.event.quit()
    return
  end

  local mods = is_test and { "tests.test_game", "tests.test_ui" }
    or is_soak and { "tests.test_soak" }
    or is_net and { "tests.test_net" } or nil
  if mods then
    for _, mod in ipairs(mods) do
      local ok, err = pcall(require, mod)
      if not ok then
        print("TEST CRASH (" .. mod .. "): " .. tostring(err))
        love.event.quit(1)
        return
      end
    end
    love.event.quit()
    return
  end
  if autostart then
    startGame() -- 无头/GUI 泛化验证：跳过菜单直达牌桌
  else
    backToMenu()
  end
end

function love.update(dt)
  if current_scene and current_scene.update then current_scene:update(dt) end
end

function love.draw()
  if current_scene and current_scene.draw then current_scene:draw() end
end

function love.mousepressed(x, y, button)
  if current_scene and current_scene.mousepressed then
    current_scene:mousepressed(x, y, button)
  end
end
