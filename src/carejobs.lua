--- Client for the CareJobs.Now healthcare jobs API.
--
-- Search open US healthcare jobs, see the hourly pay employers post, and look
-- up employers and states. The API is a remote MCP server (JSON-RPC over HTTP)
-- that needs no key: https://carejobs.now/api/mcp
--
-- Every method returns a result table or, on failure, `nil` and an error
-- table (see "Errors"). A result is the tool's data (`res.jobs`, `res.total`,
-- and so on, named as the API sends them) plus `res.text`, the readable
-- summary the server writes, and `res.data`, the plain data table.
--
-- Data from CareJobs.Now (https://carejobs.now), CC BY 4.0.
--
-- Errors: `err.code` is one of "tool" (the server ran the tool and said no),
-- "rpc" (a JSON-RPC error, see `err.rpc_code`), "http" (a non-2xx status, see
-- `err.status`), "network", "timeout" or "protocol" (the answer was not what
-- MCP promises). `err.message` is the text, and `tostring(err)` gives both.
--
-- @module carejobs
-- @license MIT, copyright O-mega Enterprise, Inc.

local json = require("dkjson")

local M = {}

M.VERSION = "1.0.0"
M.DEFAULT_BASE_URL = "https://carejobs.now"

--- Seconds a socket operation may wait. The server answers a query it has not
-- seen before in up to about 25 seconds (its database may be waking up), then
-- repeats of it in a fraction of one.
M.DEFAULT_TIMEOUT = 60

--- The kinds of job the API knows, in the order it documents them.
M.KINDS = {
  "nurses", "nurse-practitioners", "physicians", "nursing-assistants",
  "caregivers", "therapy-rehab", "mental-health", "pharmacy", "imaging", "lab",
  "surgical-techs", "emts-paramedics", "medical-assistants", "dental", "admin",
  "allied-health", "ai-training",
}

--- The sort orders of `search_jobs`.
M.SORTS = { "mixed", "newest", "highest_pay" }

--- The types of entry `employers` can list.
M.EMPLOYER_TYPES = { "employer", "ai-program", "job-board" }

-- The largest real answer (the whole job market) is about 135 KB.
local MAX_RESPONSE_BYTES = 16 * 1024 * 1024

local CA_FILES = {
  "/etc/ssl/cert.pem",                    -- macOS, Alpine
  "/etc/ssl/certs/ca-certificates.crt",   -- Debian, Ubuntu
  "/etc/pki/tls/certs/ca-bundle.crt",     -- Fedora, RHEL
  "/etc/ssl/ca-bundle.pem",               -- openSUSE
  "/opt/homebrew/etc/ca-certificates/cert.pem", -- Homebrew on Apple silicon
  "/usr/local/etc/ca-certificates/cert.pem",    -- Homebrew on Intel
}

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
  return e.code .. ": " .. e.message
end

local function new_error(code, message, extra)
  local e = { code = code, message = message }
  if extra then
    for k, v in pairs(extra) do e[k] = v end
  end
  return setmetatable(e, Error)
end

local Client = {}
Client.__index = Client

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function find_ca_file()
  for _, path in ipairs(CA_FILES) do
    if file_exists(path) then return path end
  end
  return nil
end

--- Make a client.
-- @tparam[opt] table opts
-- @tparam[opt] string opts.base_url The host (default "https://carejobs.now"); the endpoint is `<base_url>/api/mcp`.
-- @tparam[opt] number opts.timeout Seconds a socket operation may wait (default 60).
-- @tparam[opt] string opts.user_agent Default "carejobs-lua/<version>".
-- @tparam[opt] string opts.cafile A CA bundle file used to verify the server's certificate (found automatically on common systems).
-- @tparam[opt] function opts.transport Replaces the HTTP call (for tests): `function(url, payload, headers, timeout)` returning `status, content_type, body`.
-- @treturn Client
function M.new(opts)
  opts = opts or {}
  local base_url = tostring(opts.base_url or M.DEFAULT_BASE_URL):gsub("/+$", "")
  if not (base_url:match("^https?://[^/%s]+")) then
    error("base_url must be an http:// or https:// address, not " .. base_url, 2)
  end
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT
  if type(timeout) ~= "number" or timeout <= 0 then
    error("timeout must be a number of seconds above 0", 2)
  end
  local self = setmetatable({}, Client)
  self.base_url = base_url
  self.endpoint = base_url .. "/api/mcp"
  self.timeout = timeout
  self.user_agent = opts.user_agent or ("carejobs-lua/" .. M.VERSION)
  self.cafile = opts.cafile
  self.transport = opts.transport
  self.next_id = 0
  return self
end

-- HTTP -------------------------------------------------------------------------

-- Sends the request with LuaSocket (and LuaSec for https). Returns status,
-- content type and body, or nil and an error table.
local function default_transport(self, url, payload, headers, timeout)
  local ltn12 = require("ltn12")
  local is_https = url:match("^https://") ~= nil
  local http = require("socket.http")
  local request = http.request
  local https
  if is_https then
    https = require("ssl.https")
    request = https.request
  end

  local chunks, size = {}, 0
  local sink = function(chunk)
    if chunk then
      size = size + #chunk
      if size > MAX_RESPONSE_BYTES then
        return nil, "response too large"
      end
      chunks[#chunks + 1] = chunk
    end
    return 1
  end

  local req = {
    url = url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(payload),
    sink = sink,
  }
  if is_https then
    local cafile = self.cafile or find_ca_file()
    if not cafile then
      return nil, new_error("network",
        "no CA certificate file found to verify " .. url .. "; pass the cafile option")
    end
    req.protocol = "any"
    req.options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" }
    req.verify = "peer"
    req.cafile = cafile
  end

  local old_http, old_https = http.TIMEOUT, https and https.TIMEOUT
  http.TIMEOUT = timeout
  if https then https.TIMEOUT = timeout end
  local ok, _, code, response_headers = pcall(request, req)
  http.TIMEOUT = old_http
  if https then https.TIMEOUT = old_https end

  if not ok then
    return nil, new_error("network", "Could not reach " .. url .. ": " .. tostring(_))
  end
  if not _ then
    -- LuaSocket returns nil and the reason where `code` would be
    local reason = tostring(code)
    if reason == "timeout" then
      return nil, new_error("timeout", "No answer from " .. url .. " within " .. tostring(timeout) .. " s")
    end
    return nil, new_error("network", "Could not reach " .. url .. ": " .. reason)
  end
  return code, (response_headers and response_headers["content-type"]) or "", table.concat(chunks)
end

-- JSON-RPC ---------------------------------------------------------------------

local function decode_object(text, tool)
  local value, _, err = json.decode(text, 1, nil)
  if err then
    return nil, new_error("protocol", "The server did not answer with JSON", { tool = tool })
  end
  if type(value) ~= "table" then
    return nil, new_error("protocol", "The server did not answer with a JSON-RPC object", { tool = tool })
  end
  return value
end

-- Reads the JSON-RPC message out of a plain JSON body or a text/event-stream body.
local function parse_message(body, content_type, id, tool)
  if not content_type:lower():find("text/event-stream", 1, true) then
    return decode_object(body, tool)
  end
  local fallback
  local text = body:gsub("\r\n", "\n")
  local pos = 1
  while pos <= #text + 1 do
    local s, e = text:find("\n\n", pos, true)
    local event = text:sub(pos, (s or #text + 1) - 1)
    pos = (e or #text + 1) + 1
    local data = {}
    for line in (event .. "\n"):gmatch("([^\n]*)\n") do
      if line:sub(1, 5) == "data:" then
        data[#data + 1] = (line:sub(6):gsub("^ ", ""))
      end
    end
    if #data > 0 then
      local message = decode_object(table.concat(data, "\n"), tool)
      if message then
        if message.id == id then return message end
        if not fallback and (message.result ~= nil or message.error ~= nil) then
          fallback = message
        end
      end
    end
  end
  if fallback then return fallback end
  return nil, new_error("protocol", "The event stream held no JSON-RPC answer", { tool = tool })
end

local function http_error_detail(status, body, content_type, id)
  local detail = "HTTP " .. status
  local message = parse_message(body, content_type, id, nil)
  if message and type(message.error) == "table" and type(message.error.message) == "string"
      and message.error.message ~= "" then
    return detail .. ": " .. message.error.message
  end
  local text = body:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return detail end
  return detail .. ": " .. text:sub(1, 200)
end

-- Sends one JSON-RPC request and returns the result of its answer.
function Client:rpc(method, params, tool)
  self.next_id = self.next_id + 1
  local id = self.next_id
  local payload = json.encode({ jsonrpc = "2.0", id = id, method = method, params = params })
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json, text/event-stream",
    ["User-Agent"] = self.user_agent,
    ["Content-Length"] = tostring(#payload),
  }
  local status, content_type, body
  if self.transport then
    status, content_type, body = self.transport(self.endpoint, payload, headers, self.timeout)
  else
    status, content_type, body = default_transport(self, self.endpoint, payload, headers, self.timeout)
  end
  if not status then
    local err = content_type
    if type(err) ~= "table" then
      err = new_error("network", "Could not reach " .. self.endpoint .. ": " .. tostring(err))
    end
    err.tool = tool
    return nil, err
  end
  content_type = content_type or ""
  body = body or ""

  if status < 200 or status > 299 then
    return nil, new_error("http", http_error_detail(status, body, content_type, id),
      { status = status, tool = tool })
  end

  local message, err = parse_message(body, content_type, id, tool)
  if not message then return nil, err end
  if message.error ~= nil then
    if type(message.error) ~= "table" then
      return nil, new_error("protocol", "Malformed JSON-RPC error", { tool = tool })
    end
    local text = message.error.message
    if type(text) ~= "string" or text == "" then text = "JSON-RPC error" end
    return nil, new_error("rpc", text, {
      rpc_code = type(message.error.code) == "number" and message.error.code or nil,
      tool = tool,
    })
  end
  if type(message.result) ~= "table" then
    return nil, new_error("protocol", "The answer held no result", { tool = tool })
  end
  return message.result
end

local function object(t)
  return setmetatable(t, { __jsontype = "object" })
end

--- The tools the server offers, with their input schemas.
-- @treturn table|nil A list of tables (`name`, `description`, `inputSchema`, ...).
-- @treturn table|nil The error.
function Client:tools()
  local result, err = self:rpc("tools/list", object({}))
  if not result then return nil, err end
  if type(result.tools) ~= "table" then
    return nil, new_error("protocol", "tools/list answered without a tools list")
  end
  return result.tools
end

--- Call any tool by name, for a tool added after this version. Arguments keep
-- the API's names. The methods below use this.
-- @tparam string name
-- @tparam[opt] table arguments
-- @treturn table|nil The result: the data fields, plus `text` and `data`.
-- @treturn table|nil The error.
function Client:call_tool(name, arguments)
  local args = {}
  for k, v in pairs(arguments or {}) do
    if v ~= nil then args[k] = v end
  end
  local raw, err = self:rpc("tools/call", { name = name, arguments = object(args) }, name)
  if not raw then return nil, err end

  local texts = {}
  if type(raw.content) == "table" then
    for _, part in ipairs(raw.content) do
      if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
        texts[#texts + 1] = part.text
      end
    end
  end
  local text = table.concat(texts, "\n")

  if raw.isError == true then
    if text == "" then text = name .. " failed" end
    return nil, new_error("tool", text, { tool = name })
  end
  local data = raw.structuredContent
  if type(data) ~= "table" then
    return nil, new_error("protocol", name .. " answered without structured content", { tool = name })
  end
  local result = { data = data, text = text }
  return setmetatable(result, { __index = data })
end

-- The six tools -----------------------------------------------------------------

--- Search the open healthcare jobs. Every filter is optional.
-- @tparam[opt] table params
-- @tparam[opt] string params.query Words every job must carry in its title, place, department or schedule ("ICU", "night", "Houston").
-- @tparam[opt] string params.kind A kind of job, one of `carejobs.KINDS`.
-- @tparam[opt] string params.employer An employer slug ("kaiser-permanente") or name.
-- @tparam[opt] string params.state A US state: "TX" or "Texas".
-- @tparam[opt] boolean params.remote True keeps only remote jobs.
-- @tparam[opt] number params.min_hourly_usd Only jobs whose posted hourly ceiling reaches this (1 to 1000).
-- @tparam[opt] string params.sort "mixed" (default), "newest" or "highest_pay".
-- @tparam[opt] number params.limit 1 to 25 (default 10).
-- @treturn table|nil The result: `total` (every match), `pay`, `jobs` (the ones returned), `more`.
-- @treturn table|nil The error.
function Client:search_jobs(params)
  params = params or {}
  return self:call_tool("search_healthcare_jobs", {
    query = params.query,
    kind = params.kind,
    employer = params.employer,
    state = params.state,
    remote = params.remote and true or nil,
    min_hourly_usd = params.min_hourly_usd,
    sort = params.sort,
    limit = params.limit,
  })
end

--- What healthcare jobs post as hourly pay, measured from open jobs (before
-- shift differentials and bonuses). With no arguments: every kind of job. With
-- a kind: that job's pay and the employers posting the most for it. With an
-- employer: its pay overall and by kind. With both: that employer's pay for
-- that kind.
-- @tparam[opt] table params `kind` and `employer`.
function Client:pay(params)
  params = params or {}
  return self:call_tool("get_healthcare_pay", { kind = params.kind, employer = params.employer })
end

--- The pay of one kind of job and the employers posting the most for it.
-- @tparam string kind One of `carejobs.KINDS`.
function Client:pay_by_kind(kind)
  return self:pay({ kind = kind })
end

--- How many healthcare jobs are open, how many were first listed in the last 7
-- days, and the open jobs by kind of job, by state and by employer.
function Client:job_market()
  return self:call_tool("get_healthcare_job_market", {})
end

--- Open jobs by US state. With no state: every state. With a state: its jobs by
-- kind, pay, towns, employers and newest jobs. With a state and a kind: the
-- same for that kind (a kind needs a state).
-- @tparam[opt] table params `state`, `kind` and `limit` (1 to 25, how many of the newest jobs to return).
function Client:jobs_by_state(params)
  params = params or {}
  return self:call_tool("get_healthcare_jobs_by_state", {
    state = params.state, kind = params.kind, limit = params.limit,
  })
end

--- Alias of `jobs_by_state`: the states and their open jobs.
function Client:states(params)
  return self:jobs_by_state(params)
end

--- The employers (and AI-training programs and job boards) the site reads, most
-- open jobs first.
-- @tparam[opt] table params
-- @tparam[opt] string params.query Part of the name ("Kaiser", "children").
-- @tparam[opt] string params.type One of `carejobs.EMPLOYER_TYPES`.
-- @tparam[opt] string params.care A kind of care, for example "home-care" or "health-system".
-- @tparam[opt] string params.state Keep employers with open jobs in this state.
-- @tparam[opt] string params.kind Keep employers with open jobs of this kind.
-- @tparam[opt] number params.limit 1 to 100 (default 20).
function Client:employers(params)
  params = params or {}
  return self:call_tool("list_healthcare_employers", {
    query = params.query,
    type = params.type,
    care = params.care,
    state = params.state,
    kind = params.kind,
    limit = params.limit,
  })
end

--- One employer, AI-training program or job board, by slug ("kaiser-permanente")
-- or name: what it is, where it hires, its open jobs by kind, the pay it posts,
-- its newest and best-paid jobs, and links to its pages.
-- @tparam string slug
function Client:employer(slug)
  return self:call_tool("get_healthcare_employer", { employer = slug })
end

--- The kinds of job the API knows, as slugs.
-- @treturn table A new list.
function Client:kinds()
  local list = {}
  for i, kind in ipairs(M.KINDS) do list[i] = kind end
  return list
end

M.Client = Client
M.Error = Error

return M
