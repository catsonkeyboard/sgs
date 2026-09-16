-- LÖVE 配置：--test / --soak 时关闭窗口与音频（headless 可测）
--
-- 注意：headless 必须靠这里关掉窗口，而不是靠 SDL_VIDEODRIVER=dummy。
-- dummy 驱动在 macOS 上建不出 OpenGL 上下文，LÖVE 会直接弹
-- 「Unable to create OpenGL window」错误框后退出。
-- 只要这里不建窗口，用哪个 SDL 驱动都无所谓。
-- 只列真正会「跑完就退出」的模式；普通运行必须保留窗口
local HEADLESS_FLAGS = { ["--test"] = true, ["--soak"] = true }

function love.conf(t)
  t.identity = "sgs"
  t.window.title = "三国杀 · sgs"
  t.window.width = 1130
  t.window.height = 650
  t.window.vsync = 1
  -- highdpi：坐标单位=物理像素，高分屏（125%/150% 缩放）不再被系统
  -- 拉伸发糊；界面整体放大由 src/ui/scale.lua 负责。
  -- resizable：窗口可拖边调整大小（F11 全屏见 main.lua）。
  t.window.highdpi = true
  t.window.resizable = true
  t.window.minwidth = 720
  t.window.minheight = 460

  for _, a in ipairs(arg or {}) do
    if HEADLESS_FLAGS[a] then
      t.window = false
      t.audio = false
      break
    end
  end
end
