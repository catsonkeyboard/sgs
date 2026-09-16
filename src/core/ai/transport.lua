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
-- 两种真实实现，按环境二选一（UI 侧用 SGS_AI_TRANSPORT 切换）：
--   Curl  —— io.popen 调系统 curl 直连 HTTPS 接口。零依赖，但密钥要经手游戏进程。
--   Proxy —— 明文 HTTP 连本机代理（tools/ai_proxy.py），TLS 由代理负责。
--            多一个进程，但**密钥不进游戏进程**，调试也方便。
--
-- 注意：本文件在 core/ 下，禁止 require 任何 love 模块。io.popen 是标准库、
-- socket 是 LuaSocket（LÖVE 内置），都不是 love 的东西，可以放心用。
local class = require "src.class"
local Json = require "src.core.json"

local Transport = {}

-- ===== 协议差异：chat 与 responses =====
--
--   chat       OpenAI Chat Completions（/v1/chat/completions），
--              system/user 两条消息，取 choices[1].message.content
--   responses  OpenAI Responses API（/v1/responses，hy3 走这个），
--              instructions + input，取 output_text
--
-- Responses 还有一个关键能力：**关掉思维链**。
--   {"reasoning": {"effort": "none"}}
-- 实测 hy3 关掉推理后单次从 12.7 秒降到 1.4~1.7 秒（reasoning_tokens 归零）。
-- 注意参数**必须嵌套在 reasoning 对象里、值必须是 none**：
--   传 "low" 不被识别（会退回默认 high），传顶层 reasoning_effort 完全无效。
local DEFAULT_PROTOCOL = "chat"

local function buildBody(self, prompt)
  local protocol = self.protocol or DEFAULT_PROTOCOL
  if protocol == "responses" then
    local body = {
      model = self.model,
      instructions = prompt.system,
      input = prompt.user,
      stream = false,
    }
    -- effort 只认 none/low/medium/high 里服务端支持的那几个；
    -- 不传就听服务端默认（hy3 默认 high，很慢）
    if self.reasoning_effort then
      body.reasoning = { effort = self.reasoning_effort }
    end
    if self.max_output_tokens then body.max_output_tokens = self.max_output_tokens end
    return Json.encode(body)
  end
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

-- 从 Responses 的 output 数组里取助手文本。优先用顶层的 output_text
-- （服务端给的便利字段），没有就自己从 output[].content[].text 拼。
local function textFromResponses(data)
  if type(data.output_text) == "string" and data.output_text ~= "" then
    return data.output_text
  end
  local buf = {}
  for _, item in ipairs(data.output or {}) do
    if item.type == "message" then
      for _, c in ipairs(item.content or {}) do
        if c.type == "output_text" and type(c.text) == "string" then
          buf[#buf + 1] = c.text
        end
      end
    end
  end
  if #buf > 0 then return table.concat(buf, "") end
  return nil
end

-- 思维链摘要。开了推理才有的东西，调试时能看到它「想了什么」。
local function reasoningFromResponses(data)
  for _, item in ipairs(data.output or {}) do
    if item.type == "reasoning" then
      local parts = {}
      for _, s in ipairs(item.summary or {}) do
        if type(s.text) == "string" then parts[#parts + 1] = s.text end
      end
      if #parts > 0 then return table.concat(parts, " ") end
    end
  end
  return nil
end

-- 统一解析：返回 {ok=, text=, err=, reasoning=, usage=}
local function parseResponse(out, protocol)
  if not out or out == "" then return { ok = false, err = "接口无输出" } end
  local data = Json.decode(out)
  if type(data) ~= "table" then
    return { ok = false, err = "响应不是合法 JSON：" .. out:sub(1, 120) }
  end
  if data.error then
    local e = data.error
    return { ok = false, err = tostring(type(e) == "table" and (e.message or e.code) or e) }
  end

  if (protocol or DEFAULT_PROTOCOL) == "responses" then
    local text = textFromResponses(data)
    if not text then
      return { ok = false, err = "响应里没有 output_text（status="
        .. tostring(data.status) .. "）" }
    end
    return { ok = true, text = text, reasoning = reasoningFromResponses(data),
      usage = data.usage }
  end

  local content = data.choices and data.choices[1]
    and data.choices[1].message and data.choices[1].message.content
  if type(content) ~= "string" then
    return { ok = false, err = "响应缺少 choices[1].message.content" }
  end
  return { ok = true, text = content, usage = data.usage }
end

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
  elseif type(text) == "table" then
    -- 表形式可带思维链摘要（测 on_reasoning 用）：{text=..., reasoning=...}
    self._result = { ok = true, text = tostring(text.text),
      reasoning = text.reasoning }
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
  -- 根据 url 猜协议，省得每次都要写两处；显式给 protocol 则以它为准
  local url = opts.url or "https://api.openai.com/v1/chat/completions"
  self.url = url
  self.protocol = opts.protocol or (url:find("/responses", 1, true) and "responses" or "chat")
  self.model = opts.model or "gpt-4o-mini"
  self.api_key = opts.api_key or os.getenv("OPENAI_API_KEY") or ""
  self.timeout = opts.timeout or 60
  self.temperature = opts.temperature or 0.2
  self.max_tokens = opts.max_tokens or 300
  -- Responses 协议：关掉思维链能把单次调用从 12 秒压到 1.5 秒，务必显式给 none
  self.reasoning_effort = opts.reasoning_effort
  self.max_output_tokens = opts.max_output_tokens
  self.extra_headers = opts.extra_headers
  self._result = nil
  self._cmd = nil
end

function Curl:_body(prompt)
  return buildBody(self, prompt)
end

-- 静态解析入口。抽出来是为了让 UI 侧的线程版传输层复用同一套解析
-- （线程里不方便 require 项目模块，因此它只负责把原始文本传回来，
-- 解析放在主线程）。
function Curl.parse(out, protocol)
  return parseResponse(out, protocol)
end

-- ===== 跨平台 shell 工具（curl 子进程用）=====
-- macOS/Linux 走 POSIX sh（单引号转义 + rm）；Windows 走 cmd.exe
-- （双引号转义 + del，`&` 串接）。两者都必须把密钥留在临时文件里
-- （-H @文件），命令行只出现路径。
-- 检测用 package.config 的路径分隔符，不依赖 jit（线程里也稳）。
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

-- 临时文件路径：POSIX 用 os.tmpname()；Windows 的 os.tmpname 不带
-- 目录且可能落在当前目录，改用 %TEMP% 下自造名字
local function tmpPath()
  if not IS_WINDOWS then return os.tmpname() end
  local dir = os.getenv("TEMP") or "."
  return dir .. "\\sgs_ai_" .. tostring(os.time()) .. "_"
    .. tostring(math.random(100000, 999999)) .. ".tmp"
end

-- 把敏感内容写进临时文件（POSIX 下收紧为 600 权限）。
-- **密钥绝不能出现在命令行参数里**：同机任何用户 `ps aux` 就能看见，
-- 而且会进 shell 的 history 与各种进程审计日志。curl 的 `-H @文件`
-- 让我们只把文件路径留在命令行上。
local function writeSecret(lines)
  local path = tmpPath()
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  if not IS_WINDOWS then
    pcall(function() os.execute("chmod 600 '" .. path:gsub("'", "'\\''") .. "'") end)
  end
  return path
end

-- 单引号包裹，供 POSIX shell 安全使用（URL 里可能带 & ? 等字符）
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 双引号包裹，供 Windows cmd.exe 使用。& | < > ^ 在双引号内是字面量；
-- % 的变量展开无法在引号内关掉，但接口 URL 不含 %，够用。
local function winq(s)
  return '"' .. tostring(s) .. '"'
end

-- 供 UI 侧线程版传输层复用（线程里不方便 require 项目模块，
-- 所以命令拼装逻辑集中在这里，线程只拿字符串）。
local function buildCurlCommand(timeout, url, hdr_path, body_path, is_win)
  if is_win then
    return string.format(
      'curl -sS --max-time %d -X POST %s -H @%s --data-binary @%s 2>&1 & del %s %s',
      timeout, winq(url), winq(hdr_path), winq(body_path),
      winq(hdr_path), winq(body_path))
  end
  return string.format(
    "curl -sS --max-time %d -X POST %s -H @%s --data-binary @%s 2>&1; rm -f %s %s",
    timeout, shq(url), shq(hdr_path), shq(body_path),
    shq(hdr_path), shq(body_path))
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

  local cmd = buildCurlCommand(self.timeout, self.url, hdr_path, body_path,
    IS_WINDOWS)
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
  return Curl.parse(out, self.protocol)
end

-- 阻塞版接口：submit 立即执行，poll 立即拿到结果
function Curl:submit(prompt)
  self._result = self:request(prompt)
  return self._result.ok == true
end

function Curl:poll() return self._result end
function Curl:cancel() self._result = nil end

-- ===== Proxy：明文连本机代理，TLS 交给代理 =====
--
-- 与 Curl 的区别不只是「换了个发请求的方式」：
--   - 游戏进程**不需要 API key**（key 只配在代理那边），泄露面小一个量级；
--   - 请求是普通 Lua 代码，能在测试里用真 socket 做端到端验证；
--   - 重试、缓存、多模型路由可以加在代理里，不用动游戏。
-- 代价：要额外起一个进程（./tools/ai_proxy.py）。
local Proxy = class("Proxy")

function Proxy:init(opts)
  opts = opts or {}
  -- 只连回环地址，且默认端口与 ai_proxy.py 保持一致
  local base = opts.url or opts.proxy or "http://127.0.0.1:8899"
  self.base = base
  self.protocol = opts.protocol or "chat"
  local default_path = (self.protocol == "responses") and "/v1/responses"
    or "/v1/chat/completions"
  self.url = opts.path and (base .. opts.path) or (base .. default_path)
  self.model = opts.model or "gpt-4o-mini"
  self.api_key = opts.api_key or ""   -- 一般留空：代理那边已经配了
  self.timeout = opts.timeout or 90
  self.temperature = opts.temperature or 0.2
  self.max_tokens = opts.max_tokens or 300
  self.reasoning_effort = opts.reasoning_effort
  self.max_output_tokens = opts.max_output_tokens
  self._result = nil
end

function Proxy:_body(prompt)
  return buildBody(self, prompt)
end

-- 代理是否活着（GET /health）。给 UI 侧做「没起代理就别干等」的提示用。
function Proxy:health()
  local http = require "socket.http"
  local ltn12 = require "ltn12"
  local old = http.TIMEOUT
  http.TIMEOUT = 2
  local out = {}
  local ok, code = http.request({
    url = self.base .. "/health",
    method = "GET",
    sink = ltn12.sink.table(out),
  })
  http.TIMEOUT = old
  return ok ~= nil and code == 200, code
end

function Proxy:request(prompt)
  local http = require "socket.http"
  local ltn12 = require "ltn12"
  local body = self:_body(prompt)

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["Content-Length"] = #body,
  }
  if self.api_key ~= "" then
    headers["Authorization"] = "Bearer " .. self.api_key
  end

  local out = {}
  -- http.TIMEOUT 是 LuaSocket 的**全局**设置，用完必须还原，
  -- 否则会把联机模块（阶段 D）的超时一起改掉
  local old = http.TIMEOUT
  http.TIMEOUT = self.timeout
  local ok, code = http.request({
    url = self.url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(body),
    sink = ltn12.sink.table(out),
  })
  http.TIMEOUT = old

  -- 失败时第二返回值是错误消息，不是状态码
  if not ok then
    return { ok = false, err = string.format("连不上代理 %s：%s", self.base, tostring(code)) }
  end
  if code ~= 200 then
    return { ok = false, err = string.format("代理返回 %s：%s", tostring(code),
      (table.concat(out):sub(1, 120))) }
  end
  return parseResponse(table.concat(out), self.protocol)
end

-- 阻塞版接口：submit 立即执行，poll 立即拿到结果
function Proxy:submit(prompt)
  self._result = self:request(prompt)
  return self._result.ok == true
end

function Proxy:poll() return self._result end
function Proxy:cancel() self._result = nil end

Transport.Mock = Mock
Transport.Curl = Curl
Transport.Proxy = Proxy
-- 导出给 UI 层的线程版复用：协议请求体只有这一份实现，
-- 免得 chat/responses 的差异在三个地方各写一遍然后走样
Transport.buildBody = buildBody
Transport.parseResponse = parseResponse

-- 按 URL 猜协议。显式配置优先。
function Transport.guessProtocol(url)
  if type(url) ~= "string" then return DEFAULT_PROTOCOL end
  if url:find("/responses", 1, true) then return "responses" end
  return "chat"
end
Transport.mock = function(opts) return Mock.create(opts or {}) end
Transport.curl = function(opts) return Curl.create(opts or {}) end
Transport.proxy = function(opts) return Proxy.create(opts or {}) end
-- 命令拼装与平台检测单独导出：UI 线程版传输层复用命令格式，单测跨平台断言
Transport.buildCurlCommand = buildCurlCommand
Transport.isWindows = IS_WINDOWS

return Transport
