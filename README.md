# carejobs-lua

Lua client for the [CareJobs.Now](https://carejobs.now) healthcare jobs API. Search open US healthcare jobs, see the hourly pay employers post, and look up employers and states.

- Free, no API key.
- Lua 5.1 to 5.5. Needs [LuaSocket](https://luarocks.org/modules/lunarmodules/luasocket), [LuaSec](https://luarocks.org/modules/brunoos/luasec) (https, with certificate checks) and [dkjson](https://luarocks.org/modules/dhkolf/dkjson).
- Every method returns a result table, or `nil` and an error table.
- The same API is a remote MCP server at <https://carejobs.now/api/mcp>, so any MCP client can use it too.

## Where the data comes from

CareJobs.Now is a free US healthcare job board. Its jobs are read daily from the career sites of US hospitals, health systems, clinics and care employers, and the pay is what each posting states (hourly rates before shift differentials and bonuses). Every job links to its page on CareJobs.Now, where the user applies. Data and docs: <https://carejobs.now/data>.

Data from CareJobs.Now (https://carejobs.now), CC BY 4.0.

## Install

```sh
luarocks install carejobs
```

## Quick start

```lua
local carejobs = require("carejobs")

local client = carejobs.new()

local jobs, err = client:search_jobs({ query = "ICU", kind = "nurses", state = "TX", limit = 5 })
if not jobs then
  error(tostring(err))
end

print(jobs.total .. " jobs match")
for _, job in ipairs(jobs.jobs) do
  print(job.title .. " | " .. job.employer .. " | " .. job.location .. " | " .. job.url)
end

local pay = client:pay_by_kind("nurses")
print("Median posted pay for nurses: $" .. pay.pay.median .. "/hr")

-- Every answer also carries the server's readable summary:
print(pay.text)
```

A runnable version is in [`examples/search.lua`](examples/search.lua): `lua examples/search.lua OH`.

## Methods

Call them with a colon (`client:search_jobs{...}`). Each returns a result table or `nil, err`. A result is the tool's data (`res.jobs`, `res.total`, and so on, named as the API sends them), plus `res.text`, a readable summary written by the server, and `res.data`, the plain data table. Where the API sends `null`, the field is `nil`. Every parameter is optional unless said otherwise.

| Method | What it answers |
| --- | --- |
| `search_jobs{query, kind, employer, state, remote, min_hourly_usd, sort, limit}` | Open jobs. Fields: `total`, `pay`, `jobs`, `more`. `limit` is 1 to 25. `sort` is `mixed`, `newest` or `highest_pay`. |
| `pay{kind, employer}` | Posted hourly pay: every kind, one kind with the employers posting the most, one employer, or both. |
| `pay_by_kind(kind)` | `pay` for one kind of job. |
| `job_market()` | How many jobs are open, new in the last 7 days, and the open jobs by kind, state and employer. |
| `jobs_by_state{state, kind, limit}` | Every state, one state, or one kind of job in one state (a kind needs a state). |
| `states{state, kind, limit}` | Alias of `jobs_by_state`. |
| `employers{query, type, care, state, kind, limit}` | The employers, AI-training programs and job boards the site reads. `limit` is 1 to 100. |
| `employer(slug)` | One employer by slug (`"kaiser-permanente"`) or name. |
| `kinds()` | The 17 kinds of job as slugs. Also the list `carejobs.KINDS`. |
| `tools()` | The server's tools with their input schemas. |
| `call_tool(name, arguments)` | Any tool, for a tool this version does not know yet. |

```lua
local ohio = client:states({ state = "OH", kind = "nursing-assistants" })
print(ohio.open_jobs .. " CNA jobs in Ohio")

local kaiser = client:employers({ query = "Kaiser", limit = 3 })
for _, entry in ipairs(kaiser.entries) do
  print(entry.name .. " (" .. entry.open_jobs .. " open jobs)")
end
```

### Options

```lua
local client = carejobs.new({
  base_url = "https://carejobs.now", -- default
  timeout = 60,                      -- seconds a socket operation may wait, default 60
  user_agent = "my-app/1.0",         -- default "carejobs-lua/<version>"
  cafile = "/etc/ssl/cert.pem",      -- CA bundle for https, found automatically on common systems
})
```

The server answers a query it has not seen before in up to about 25 seconds, then repeats of it in a fraction of one, which is why the default timeout is a minute.

### Errors

A failure returns `nil` and an error table. `err.code` says which kind, `err.message` is the text, and `tostring(err)` gives both:

```lua
local res, err = client:jobs_by_state({ kind = "nurses" }) -- a kind without a state
if not res then
  print(err.code, err.message)
  -- "tool": the server ran the tool and said no
  -- "rpc": a JSON-RPC error (err.rpc_code)
  -- "http": a non-2xx status (err.status)
  -- "network", "timeout": no answer
  -- "protocol": the answer was not what MCP promises
end
```

### Kinds

`nurses`, `nurse-practitioners`, `physicians`, `nursing-assistants`, `caregivers`, `therapy-rehab`, `mental-health`, `pharmacy`, `imaging`, `lab`, `surgical-techs`, `emts-paramedics`, `medical-assistants`, `dental`, `admin`, `allied-health`, `ai-training`.

## Tests

```sh
lua -e 'package.path="src/?.lua;"..package.path' tests/test.lua   # offline, with a fake transport
lua -e 'package.path="src/?.lua;"..package.path' tests/live.lua   # calls the live API
```

## Plain JSON

Without this library the same data is plain JSON: <https://carejobs.now/roles.json> (open jobs by kind of job and employer) and <https://carejobs.now/pay.json> (posted hourly pay by kind of job).

## License

Code: MIT, copyright O-mega Enterprise, Inc. Data: CC BY 4.0, credit CareJobs.Now.
