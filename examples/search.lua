-- lua examples/search.lua OH
local carejobs = require("carejobs")

local state = arg[1] or "TX"
local client = carejobs.new()

local res, err = client:search_jobs({ kind = "nurses", state = state, limit = 5 })
if not res then
  io.stderr:write(tostring(err), "\n")
  os.exit(1)
end

print(res.total .. " nursing jobs in " .. state)
for _, job in ipairs(res.jobs) do
  print(job.title .. " | " .. job.employer .. " | " .. (job.location or "") .. " | " .. job.url)
end
