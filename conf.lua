-- LÖVE 配置：--test 时关闭窗口与音频（headless 可测）
function love.conf(t)
  t.identity = "sgs-love"
  t.window.title = "三国杀 · sgs-love"
  t.window.width = 1130
  t.window.height = 650
  t.window.vsync = 1

  for _, a in ipairs(arg or {}) do
    if a == "--test" then
      t.window = false
      t.audio = false
    end
  end
end
