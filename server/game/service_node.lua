local moon = require("moon")
local setup = require("common.setup")
local conf = ...

---@class node_context:base_context
---@field scripts node_scripts
local context ={
    logics = {},
}

setup(context)

print(string.format("node context %s", print_r(context, true)))

moon.shutdown(function()
    moon.quit()
end)
