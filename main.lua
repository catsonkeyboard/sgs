-- 入口：--test 无头跑测试；否则进入菜单 → 牌桌
local is_test, autostart = false, false
for _, a in ipairs(arg or {}) do
  if a == "--test" then is_test = true end
  if a == "--autostart" then autostart = true end
end

local current_scene = nil

local startGame, backToMenu

startGame = function()
  local RoomScene = require "src.ui.scene_room"
  current_scene = RoomScene.create(backToMenu)
end

backToMenu = function()
  local MenuScene = require "src.ui.scene_menu"
  current_scene = MenuScene.create(startGame)
end

function love.load()
  if is_test then
    for _, mod in ipairs { "tests.test_game", "tests.test_ui" } do
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
