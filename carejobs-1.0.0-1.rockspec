rockspec_format = "3.0"
package = "carejobs"
version = "1.0.0-1"
source = {
   url = "git+https://github.com/yumaheymans/carejobs-lua.git",
   tag = "v1.0.0",
}
description = {
   summary = "Client for the free CareJobs.Now US healthcare jobs API",
   detailed = [[
      Search open US healthcare jobs, see the hourly pay employers post, and
      look up employers and states from Lua. The API is free, needs no key and
      is also a remote MCP server at https://carejobs.now/api/mcp.
      Data from CareJobs.Now (https://carejobs.now), CC BY 4.0.
   ]],
   homepage = "https://carejobs.now/data",
   license = "MIT",
   maintainer = "O-mega Enterprise, Inc. <hello@carejobs.now>",
   labels = { "healthcare", "jobs", "api-client", "http", "json" },
}
dependencies = {
   "lua >= 5.1",
   "luasocket >= 3.0",
   "luasec >= 1.0",
   "dkjson >= 2.5",
}
build = {
   type = "builtin",
   modules = {
      carejobs = "src/carejobs.lua",
   },
   copy_directories = { "examples" },
}
