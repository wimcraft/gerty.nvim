--- `replace` on a chat-only provider: the answer comes back as text rather
--- than through a temp file, and has to land in the buffer intact.

local T = require("tests.helpers")
local gerty = require("gerty")

local function setup()
  gerty.setup({
    providers = { ["local"] = { type = "lmstudio", models = { "a-local-model" } } },
  })
end

--- Runs replace against a mocked chat reply and returns the resulting lines.
--- @param lines string[]
--- @param replacement string
--- @return string[]
local function replace_with(lines, replacement)
  local mock = T.mock_jobs()
  mock.reply = {
    status = "ok",
    output = T.chat_response(vim.json.encode({ replacement = replacement })),
  }
  local buf = T.buffer_with_selection(lines, 2, 3)
  local done = false
  local original = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(...)
    done = true
    return original(...)
  end
  gerty.replace({ instruction = "rename x to total" })
  T.wait_for(function() return done end)
  vim.api.nvim_buf_set_lines = original
  T.unmock_jobs(mock)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

T.test("the selected range is replaced and indentation survives", function()
  setup()
  local out = replace_with(
    { "function f()", "    local x = 1", "    return x", "end" },
    "    local total = 1\n    return total"
  )
  T.eq(out[1], "function f()", "line above untouched")
  T.eq(out[2], "    local total = 1")
  T.eq(out[3], "    return total")
  T.eq(out[4], "end", "line below untouched")
end)

T.test("a fence wrapping the whole answer is stripped", function()
  setup()
  local out = replace_with(
    { "function f()", "    local x = 1", "    return x", "end" },
    "```lua\n    local total = 1\n    return total\n```"
  )
  T.eq(out[2], "    local total = 1")
  T.eq(out[3], "    return total")
end)

T.test("a fence inside the replacement is preserved", function()
  setup()
  local out = replace_with(
    { "a", "-- doc:", "-- end", "b" },
    "-- doc:\n-- ```lua\n-- x()\n-- ```"
  )
  T.eq(out[3], "-- ```lua", "only a whole-answer fence is removed")
end)

T.test("an empty answer leaves the buffer alone", function()
  setup()
  local mock = T.mock_jobs()
  mock.reply = { status = "ok", output = T.chat_response(vim.json.encode({ replacement = "" })) }
  local buf = T.buffer_with_selection({ "a", "b", "c", "d" }, 2, 3)
  local messages = T.capture_notify(function()
    gerty.replace({ instruction = "x" })
    T.wait_for(function() return false end, 300)
  end)
  T.eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ","), "a,b,c,d")
  T.ok(#messages > 0, "the user is told nothing usable came back")
  T.unmock_jobs(mock)
end)

T.test("an errored request leaves the buffer alone", function()
  setup()
  local mock = T.mock_jobs()
  mock.reply = { status = "error", output = "", error = "boom" }
  local buf = T.buffer_with_selection({ "a", "b", "c", "d" }, 2, 3)
  local messages = T.capture_notify(function()
    gerty.replace({ instruction = "x" })
    T.wait_for(function() return false end, 300)
  end)
  T.eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ","), "a,b,c,d")
  T.ok(table.concat(messages, " "):find("boom", 1, true), "the error is surfaced")
  T.unmock_jobs(mock)
end)
