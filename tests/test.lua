-- Offline tests: no framework needed. Run from the repository root with
--   lua -e 'package.path="src/?.lua;"..package.path' tests/test.lua
-- The HTTP call is replaced by a fake transport, so nothing leaves the machine.

local carejobs = require("carejobs")
local json = require("dkjson")

local failures = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local function answer(structured, text)
  return json.encode({
    jsonrpc = "2.0", id = 1,
    result = {
      content = { { type = "text", text = text or "summary" } },
      structuredContent = structured,
    },
  })
end

local sent
local client = carejobs.new({ transport = function(url, payload, headers, timeout)
  sent = { url = url, raw = payload, payload = json.decode(payload), headers = headers, timeout = timeout }
  return 200, "application/json", answer({ total = 3, jobs = { { title = "RN" } } }, "three jobs")
end })

local res = client:search_jobs({ query = "ICU", kind = "nurses", state = "TX", limit = 5 })
check("search url", sent.url == "https://carejobs.now/api/mcp")
check("search method", sent.payload.method == "tools/call" and sent.payload.params.name == "search_healthcare_jobs")
local a = sent.payload.params.arguments
check("search arguments", a.query == "ICU" and a.kind == "nurses" and a.state == "TX" and a.limit == 5 and a.remote == nil)
check("search result data", res.total == 3 and res.data.jobs[1].title == "RN" and res.jobs[1].title == "RN")
check("search result text", res.text == "three jobs")

client:job_market()
check("empty arguments are an object", sent.raw:find('"arguments":{}', 1, true) ~= nil)

client:pay_by_kind("physicians")
check("pay arguments", sent.payload.params.name == "get_healthcare_pay" and sent.payload.params.arguments.kind == "physicians")

client:states({ state = "OH", kind = "nursing-assistants" })
check("states arguments", sent.payload.params.name == "get_healthcare_jobs_by_state"
  and sent.payload.params.arguments.state == "OH" and sent.payload.params.arguments.kind == "nursing-assistants")

client:employers({ query = "Kaiser", limit = 3 })
check("employers arguments", sent.payload.params.name == "list_healthcare_employers"
  and sent.payload.params.arguments.query == "Kaiser" and sent.payload.params.arguments.limit == 3)

client:employer("cvs-health")
check("employer arguments", sent.payload.params.arguments.employer == "cvs-health")

check("17 kinds", #client:kinds() == 17 and client:kinds()[17] == "ai-training")

-- a text/event-stream answer
local sse = carejobs.new({ transport = function()
  return 200, "text/event-stream", "event: message\ndata: " .. answer({ open_jobs = 9 }) .. "\n\n"
end })
check("event stream", sse:job_market().open_jobs == 9)

-- failures
local function code_of(transport, call)
  local c = carejobs.new({ transport = transport })
  local r, err = call(c)
  if r then return "none" end
  return err.code
end
check("tool error", code_of(function()
  return 200, "application/json", json.encode({ jsonrpc = "2.0", id = 1,
    result = { isError = true, content = { { type = "text", text = "bad state" } } } })
end, function(c) return c:jobs_by_state({ state = "ZZ" }) end) == "tool")
check("rpc error", code_of(function()
  return 200, "application/json", json.encode({ jsonrpc = "2.0", id = 1, error = { code = -32601, message = "no such method" } })
end, function(c) return c:job_market() end) == "rpc")
check("http error", code_of(function() return 503, "text/plain", "down" end,
  function(c) return c:job_market() end) == "http")
check("protocol error", code_of(function() return 200, "text/html", "<html>" end,
  function(c) return c:job_market() end) == "protocol")
check("missing structured content", code_of(function()
  return 200, "application/json", json.encode({ jsonrpc = "2.0", id = 1, result = { content = {} } })
end, function(c) return c:job_market() end) == "protocol")
check("transport failure", code_of(function() return nil, { code = "timeout", message = "slow" } end,
  function(c) return c:job_market() end) == "timeout")

local _, err = carejobs.new({ transport = function() return 503, "text/plain", "down" end }):job_market()
check("error text", tostring(err) == "http: HTTP 503: down" and err.status == 503)

check("bad base url", not pcall(carejobs.new, { base_url = "not a url" }))

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
