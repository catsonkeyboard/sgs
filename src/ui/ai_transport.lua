-- AI 传输层的 LÖVE 实现：后台线程 + curl，主线程不阻塞
--
-- 为什么是线程而不是直接 socket.http：
--   1. LÖVE 内置的 LuaSocket 没有 luasec，`ssl.https` 直接 require 失败，
--      而 LLM 接口一律是 HTTPS —— 只能借系统 curl；
--   2. io.popen + curl 是**阻塞**的（1~3 秒），放在主线程会把整局卡成幻灯片。
-- 于是：主线程只把请求体丢进 Channel，线程负责阻塞地跑 curl，
-- 主线程每帧 poll 一次拿结果。线程代码故意写得极简（不 require 任何项目
-- 模块），因为 LÖVE 的线程是独立 Lua 状态，package.path 不共享。
local class = require "src.class"
local Json = require "src.core.json"
local TransportLib = require "src.core.ai.transport"
local Curl = TransportLib.Curl

-- 线程体：收一个 job，跑 curl，把原始响应文本推回 outbox
-- 两套线程体：
--   curl   —— io.popen 调系统 curl 直连 HTTPS（密钥要带过去）
--   socket —— 用 LuaSocket 明文连本机代理（tools/ai_proxy.py），密钥不进游戏
-- 线程里 require "socket" 是可行的（LÖVE 把 LuaSocket 编译进去了，实测可用），
-- 但项目自己的模块不行：线程是独立 Lua 状态，package.path 不共享。
local THREAD_CODE = [[
local inbox, outbox = ...
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
local function viaSocket(job)
  local ok, http = pcall(require, "socket.http")
  local ok2, ltn12 = pcall(require, "ltn12")
  if not (ok and ok2) then
    outbox:push('{"error":{"message":"线程内无法加载 socket.http"}}')
    return
  end
  http.TIMEOUT = job.timeout
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["Content-Length"] = tostring(#job.body),
  }
  if job.key and job.key ~= "" then
    headers["Authorization"] = "Bearer " .. job.key
  end
  local out = {}
  local ok3, code = http.request({
    url = job.url, method = "POST", headers = headers,
    source = ltn12.source.string(job.body), sink = ltn12.sink.table(out),
  })
  if not ok3 then
    outbox:push('{"error":{"message":"' .. tostring(code):gsub('"', "'") .. '"}}')
    return
  end
  outbox:push(table.concat(out))
end
-- 敏感内容写进 600 权限的临时文件：密钥不能出现在命令行参数里，
-- 否则同机任何用户 ps 一下就能看见。curl 的 -H @文件 让命令行只留路径。
local function writeSecret(lines)
  local path = os.tmpname()
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  pcall(function() os.execute("chmod 600 " .. shq(path)) end)
  return path
end
while true do
  local job = inbox:demand()
  if type(job) ~= "table" then break end
  if job.mode == "socket" then
    viaSocket(job)
  else
    local body_path = writeSecret({ job.body })
    local headers = { "Content-Type: application/json", "Accept: application/json" }
    if job.key and job.key ~= "" then
      headers[#headers + 1] = "Authorization: Bearer " .. job.key
    end
    local hdr_path = writeSecret(headers)
    if not body_path or not hdr_path then
      outbox:push("")
    else
      local cmd = string.format(
        "curl -sS --max-time %d -X POST %s -H @%s --data-binary @%s 2>&1; rm -f %s %s",
        job.timeout, shq(job.url), shq(hdr_path), shq(body_path),
        shq(hdr_path), shq(body_path))
      local h = io.popen(cmd, "r")
      local out = h and h:read("*a") or ""
      if h then h:close() end
      outbox:push(out)
    end
  end
end
]]

local Threaded = class("Threaded")

function Threaded:init(opts)
  opts = opts or {}
  -- mode: "curl"（直连 HTTPS） / "socket"（明文连本机代理）
  self.mode = opts.mode or "curl"
  self.url = opts.url or (self.mode == "socket"
    and "http://127.0.0.1:8899/v1/chat/completions"
    or "https://api.openai.com/v1/chat/completions")
  self.protocol = opts.protocol or TransportLib.guessProtocol(self.url)
  self.model = opts.model or "gpt-4o-mini"
  self.api_key = opts.api_key or ""
  self.timeout = opts.timeout or 60
  self.temperature = opts.temperature or 0.2
  self.max_tokens = opts.max_tokens or 300
  -- Responses 协议（TokenHub hy3）必须显式关掉思维链，否则单次 10 秒以上
  self.reasoning_effort = opts.reasoning_effort
  self.max_output_tokens = opts.max_output_tokens

  self.inbox = love.thread.newChannel()
  self.outbox = love.thread.newChannel()
  self.thread = love.thread.newThread(THREAD_CODE)
  self.thread:start(self.inbox, self.outbox)
  self.waiting = false
  self.discard = 0     -- 已取消但还会回来的结果数量
  self.last_error = nil
end

-- 请求体交给 core 的统一实现，chat / responses 的差异只在一处维护
function Threaded:_body(prompt)
  return TransportLib.buildBody(self, prompt)
end

function Threaded:submit(prompt)
  if self.thread:getError() then return false end
  -- 只传字符串：Channel 没法序列化函数，prompt 里的 view/actions 带对象
  self.inbox:push({
    mode = self.mode,
    body = self:_body(prompt),
    url = self.url,
    key = self.api_key,
    timeout = self.timeout,
  })
  self.waiting = true
  return true
end

function Threaded:poll()
  local out = self.outbox:pop()
  if out == nil then return nil end
  if self.discard > 0 then
    -- 这是被取消的那次请求姗姗来迟的结果，不能拿它当答案
    self.discard = self.discard - 1
    return nil
  end
  self.waiting = false
  local res = Curl.parse(out, self.protocol)
  if not res.ok then self.last_error = res.err end
  return res
end

-- 已经发出的 curl 收不回来，只能把结果标记为「回来就丢弃」
function Threaded:cancel()
  if self.waiting then
    self.discard = self.discard + 1
    self.waiting = false
  end
end

function Threaded:isAlive()
  return self.thread:isRunning()
end

-- 协议推断：显式配置 > URL 特征 > 默认 responses
-- （本项目当前接入的 TokenHub hy3 走 Responses API，所以默认给它）
local function resolveProtocol(url)
  local explicit = os.getenv("SGS_AI_PROTOCOL")
  if explicit == "chat" or explicit == "responses" then return explicit end
  if url and url:find("/chat/completions", 1, true) then return "chat" end
  return "responses"
end

-- 环境变量配置：
--   SGS_AI_TRANSPORT=proxy（推荐）  连本机代理 tools/ai_proxy.py，密钥不进游戏
--   SGS_AI_TRANSPORT=curl（默认）   直连 HTTPS，需要 SGS_AI_URL + SGS_AI_KEY
--   SGS_AI_PROTOCOL=chat|responses  接口形态（默认按 URL 猜，猜不出按 responses）
--   SGS_AI_REASONING=none|low|...   Responses 的思维链强度。
--                                   **默认 none**：hy3 开着思维链单次要 10 秒以上，
--                                   关掉后 1.5 秒。这是能不能玩下去的关键开关。
-- 没配就返回 nil + 原因，让上层决定是降级还是提示用户
-- opts.reasoning 可覆盖 SGS_AI_REASONING（菜单「AI 思考」开关传入；
-- 思维链开启时单次请求可达 12 秒以上，超时同步放宽到 150 秒）
local function fromEnv(opts)
  opts = opts or {}
  local model = os.getenv("SGS_AI_MODEL") or "hy3"
  local mode = os.getenv("SGS_AI_TRANSPORT") or "curl"
  local effort = opts.reasoning or os.getenv("SGS_AI_REASONING") or "none"
  -- 思考开启（非 none）时给足思维链 + 重试的时间余量
  local timeout = (effort ~= "none" and effort ~= "") and 150 or 90

  if mode == "proxy" then
    local base = os.getenv("SGS_AI_PROXY") or "http://127.0.0.1:8899"
    local protocol = resolveProtocol(nil)
    local path = (protocol == "responses") and "/v1/responses" or "/v1/chat/completions"
    return Threaded.create({
      mode = "socket",
      url = base .. path,
      protocol = protocol,
      model = model,
      reasoning_effort = effort,
      timeout = timeout,
    }), nil
  end

  local url = os.getenv("SGS_AI_URL")
  local key = os.getenv("SGS_AI_KEY") or os.getenv("OPENAI_API_KEY")
  if not url or url == "" then
    return nil, "未设置 SGS_AI_URL（模型接口地址）"
  end
  if not key or key == "" then
    return nil, "未设置 SGS_AI_KEY（接口密钥）"
  end
  return Threaded.create({
    mode = "curl",
    url = url,
    protocol = resolveProtocol(url),
    api_key = key,
    model = model,
    reasoning_effort = effort,
    timeout = timeout,
  }), nil
end

return { Threaded = Threaded, fromEnv = fromEnv }
