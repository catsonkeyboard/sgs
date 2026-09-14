-- AI 传输层：把「提示词 → LLM 输出」这件事抽象掉
--
-- 接口只有三个方法，方便替换实现而不动 AI 逻辑：
--   submit(prompt) -> bool   提交一次请求（prompt = {system=, user=, ...}）
--   poll()         -> nil | {ok=bool, text=string, err=string}
--                     nil 表示还没结果，调用方应过一会儿再来问（不阻塞）
--   cancel()                 放弃当前请求
--
-- 为什么必须异步：LLM 一次往返 1~3 秒，同步等待会把 LÖVE 主线程整个卡住。
-- 因此 UI 侧的实现必须走 love.thread（见 src/ui/ai_transport.lua），
-- 这里的 Curl 实现是**阻塞**的，只适合测试或以线程方式调用。
--
-- 注意：本文件在 core/ 下，禁止 require 任何 love 模块。io.popen 是标准库，
-- 不是 love 的东西，可以放心用。
local class = require "src.class"
local Json = require "src.core.json"

local Transport = {}

-- ===== Mock：不联网，用于跑通链路与单测 =====
-- responder(prompt, n) -> 输出字符串（返回 nil 表示模拟失败）
-- 也可以给 queue（预设输出，逐个消费）
-- delay：poll 前要先空转几次，用来验证「思考中」这条异步路径真的能走通
local Mock = class("Mock")

function Mock:init(opts)
  opts = opts or {}
  self.responder = opts.responder
  self.queue = opts.queue or {}
  self.delay = opts.delay or 0
  self.calls = {}      -- 记录每次收到的 prompt，便于断言
  self._result = nil
  self._wait = 0
end

function Mock:submit(prompt)
  self.calls[#self.calls + 1] = prompt
  local text
  if self.responder then
    text = self.responder(prompt, #self.calls)
  else
    text = table.remove(self.queue, 1)
  end
  if text == nil then
    self._result = { ok = false, err = "mock 未给出响应" }
  else
    self._result = { ok = true, text = tostring(text) }
  end
  self._wait = self.delay
  return true
end

function Mock:poll()
  if self._wait > 0 then self._wait = self._wait - 1 return nil end
  return self._result
end

function Mock:cancel()
  self._result = nil
  self._wait = 0
end

-- ===== Curl：调系统 curl 打 LLM 的 HTTPS 接口（阻塞）=====
--
-- 为什么不用 socket.http：LÖVE 内置的 LuaSocket 没有 luasec，
-- `ssl.https` 直接 require 失败，而所有正经 LLM 接口都是 HTTPS。
-- 系统 curl 支持 TLS，io.popen 在 LÖVE 里实测可用，于是走子进程。
-- 代价是阻塞——因此这个实现要么放在 love.thread 的 worker 里用，
-- 要么只在 headless 脚本里用。
local Curl = class("Curl")

function Curl:init(opts)
  opts = opts or {}
  self.url = opts.url or "https://api.openai.com/v1/chat/completions"
  self.model = opts.model or "gpt-4o-mini"
  self.api_key = opts.api_key or os.getenv("OPENAI_API_KEY") or ""
  self.timeout = opts.timeout or 60
  self.temperature = opts.temperature or 0.2
  self.max_tokens = opts.max_tokens or 300
  self._result = nil
  self._cmd = nil
end

function Curl:_body(prompt)
  return Json.encode({
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens,
    messages = {
      { role = "system", content = prompt.system },
      { role = "user", content = prompt.user },
    },
  })
end

-- 解析接口返回的原始 JSON，取出 choices[1].message.content。
-- 抽成静态方法是为了让 UI 侧的线程版传输层复用同一套解析（线程里不方便
-- require 项目模块，因此它只负责把原始文本传回来，解析放在主线程）。
function Curl.parse(out)
  if not out or out == "" then return { ok = false, err = "curl 无输出" } end
  local data = Json.decode(out)
  if type(data) ~= "table" then
    return { ok = false, err = "响应不是合法 JSON：" .. out:sub(1, 120) }
  end
  if data.error then
    return { ok = false, err = tostring(data.error.message or data.error) }
  end
  local content = data.choices and data.choices[1]
    and data.choices[1].message and data.choices[1].message.content
  if type(content) ~= "string" then
    return { ok = false, err = "响应缺少 choices[1].message.content" }
  end
  return { ok = true, text = content }
end

-- 单引号包裹，供 shell 安全使用（URL 里可能带 & ? 等字符）
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 把敏感内容写进 600 权限的临时文件。
-- **密钥绝不能出现在命令行参数里**：同机任何用户 `ps aux` 就能看见，
-- 而且会进 shell 的 history 与各种进程审计日志。curl 的 `-H @文件`
-- 让我们只把文件路径留在命令行上。
local function writeSecret(lines)
  local path = os.tmpname()
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  pcall(function() os.execute("chmod 600 " .. shq(path)) end)
  return path
end

-- 同步执行。返回 {ok=, text=, err=}
function Curl:request(prompt)
  -- 请求体同样走临时文件：塞在命令行里会被参数长度限制卡住
  local body_path = writeSecret({ self:_body(prompt) })
  if not body_path then return { ok = false, err = "无法创建临时文件" } end
  local headers = { "Content-Type: application/json", "Accept: application/json" }
  if self.api_key and self.api_key ~= "" then
    headers[#headers + 1] = "Authorization: Bearer " .. self.api_key
  end
  for _, h in ipairs(self.extra_headers or {}) do headers[#headers + 1] = h end
  local hdr_path = writeSecret(headers)
  if not hdr_path then
    os.remove(body_path)
    return { ok = false, err = "无法创建临时文件" }
  end

  local cmd = string.format(
    "curl -sS --max-time %d -X POST %s -H @%s --data-binary @%s 2>&1; rm -f %s %s",
    self.timeout, shq(self.url), shq(hdr_path), shq(body_path),
    shq(hdr_path), shq(body_path))
  local handle = io.popen(cmd, "r")
  if not handle then
    os.remove(body_path)
    os.remove(hdr_path)
    return { ok = false, err = "无法执行 curl" }
  end
  local out = handle:read("*a")
  handle:close()
  os.remove(body_path)
  os.remove(hdr_path)
  return Curl.parse(out)
end

-- 阻塞版接口：submit 立即执行，poll 立即拿到结果
function Curl:submit(prompt)
  self._result = self:request(prompt)
  return self._result.ok == true
end

function Curl:poll() return self._result end
function Curl:cancel() self._result = nil end

Transport.Mock = Mock
Transport.Curl = Curl
Transport.mock = function(opts) return Mock.create(opts or {}) end
Transport.curl = function(opts) return Curl.create(opts or {}) end

return Transport
