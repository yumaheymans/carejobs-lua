-- Calls the live API (network needed). Run from the repository root with
--   lua -e 'package.path="src/?.lua;"..package.path' tests/live.lua
local carejobs = require("carejobs")
local client = carejobs.new()

local function must(res, err)
  if not res then error(tostring(err), 2) end
  return res
end

local names = {}
for _, tool in ipairs(must(client:tools())) do names[#names + 1] = tool.name end
print("tools: " .. table.concat(names, ", "))

local jobs = must(client:search_jobs({ query = "ICU", kind = "nurses", state = "TX", limit = 3 }))
print(jobs.total .. " jobs match")
for _, job in ipairs(jobs.jobs) do
  print(" - " .. job.title .. " | " .. job.employer .. " | " .. job.url)
end

local pay = must(client:pay_by_kind("nurses"))
print("nurse median $" .. pay.pay.median .. "/hr")

local ohio = must(client:states({ state = "OH" }))
print("Ohio: " .. ohio.open_jobs .. " open jobs")

local employers = must(client:employers({ limit = 2 }))
print(employers.total .. " employers, first: " .. employers.entries[1].name)
