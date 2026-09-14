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
local Curl = require "src.core.ai.transport".Curl

-- 线程体：收一个 job，跑 curl，把原始响应文本推回 outbox
local THREAD_CODE = [[
local inbox, outbox = ...
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
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
]]

local Threaded = class("Threaded")

function Threaded:init(opts)
  opts = opts or {}
  self.url = opts.url or "https://api.openai.com/v1/chat/completions"
  self.model = opts.model or "gpt-4o-mini"
  self.api_key = opts.api_key or ""
  self.timeout = opts.timeout or 60
  self.temperature = opts.temperature or 0.2
  self.max_tokens = opts.max_tokens or 300

  self.inbox = love.thread.newChannel()
  self.outbox = love.thread.newChannel()
  self.thread = love.thread.newThread(THREAD_CODE)
  self.thread:start(self.inbox, self.outbox)
  self.waiting = false
  self.discard = 0     -- 已取消但还会回来的结果数量
  self.last_error = nil
end

function Threaded:_body(prompt)
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

function Threaded:submit(prompt)
  if self.thread:getError() then return false end
  -- 只传字符串：Channel 没法序列化函数，prompt 里的 view/actions 带对象
  self.inbox:push({
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
  local res = Curl.parse(out)
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

-- 环境变量配置：SGS_AI_URL / SGS_AI_KEY / SGS_AI_MODEL
-- 没配就返回 nil + 原因，让上层决定是降级还是提示用户
local function fromEnv()
  local url = os.getenv("SGS_AI_URL")
  local key = os.getenv("SGS_AI_KEY") or os.getenv("OPENAI_API_KEY")
  if not url or url == "" then
    return nil, "未设置 SGS_AI_URL（模型接口地址）"
  end
  if not key or key == "" then
    return nil, "未设置 SGS_AI_KEY（接口密钥）"
  end
  return Threaded.create({
    url = url,
    api_key = key,
    model = os.getenv("SGS_AI_MODEL") or "gpt-4o-mini",
  }), nil
end

return { Threaded = Threaded, fromEnv = fromEnv }
