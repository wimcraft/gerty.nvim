--- `replace` on a chat-only provider: the answer comes back as text rather
--- than through a temp file, and has to land in the buffer intact.

local T = require("tests.helpers")
local gerty = require("gerty")
local history = require("gerty.history")
local cache = require("gerty.cache")

local function setup()
  gerty.setup({
    providers = { ["local"] = { type = "lmstudio", models = { "a-local-model" } } },
  })
end

--- Same, plus a discovered skill named `tidy` -- enough for `#skill_names > 0`,
--- which is what opens the explanation channel.
local function setup_with_skill()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/tidy", "p")
  local f = assert(io.open(dir .. "/tidy/SKILL.md", "w"))
  f:write("# tidy\n\nClean it up.\n")
  f:close()
  gerty.setup({
    providers = { ["local"] = { type = "lmstudio", models = { "a-local-model" } } },
    skills = { dir },
  })
end

--- Runs `replace` on the chat provider with a stub reply. `reply` is
--- `{ replacement = ..., explanation = ... }` (explanation optional -- omit it
--- to model a server/endpoint that returned only the code).
--- @return string[] buffer_lines
--- @return string|nil note  the text passed to float.show, if any
--- @return boolean asked_for_explanation  whether the request's schema had the second field
local function replace_capturing(buf_lines, first, last, instruction, reply)
  local jobs = require("gerty.jobs")
  local float = require("gerty.float")
  local orig_spawn, orig_show = jobs.spawn, float.show

  local note, asked
  float.show = function(_, text)
    note = text
    return 1
  end
  jobs.spawn = function(_, opts)
    asked = (opts.stdin or ""):find('"explanation"', 1, true) ~= nil
    vim.schedule(function()
      opts.on_exit({
        status = "ok",
        output = T.chat_response(vim.json.encode(reply)),
      })
    end)
    return 1
  end

  local buf = T.buffer_with_selection(buf_lines, first, last)
  local done = false
  local orig_set = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(...)
    done = true
    return orig_set(...)
  end
  gerty.replace({ instruction = instruction })
  T.wait_for(function() return done end)

  vim.api.nvim_buf_set_lines = orig_set
  jobs.spawn, float.show = orig_spawn, orig_show
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false), note, asked == true
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

-- explanation channel -----------------------------------------------------

T.test("a skilled chat replace: code to the buffer, explanation field to a float", function()
  setup_with_skill()
  history.clear()
  local out, note, asked = replace_capturing(
    { "aa", "teh cat", "sat", "bb" },
    2,
    3,
    "/tidy fix it",
    { replacement = "the cat\nsat", explanation = "Fixed 'teh' -> 'the'." }
  )

  T.ok(asked, "a skill was active, so the request asks for the explanation field")
  T.eq(out[1], "aa", "line above untouched")
  T.eq(out[2], "the cat")
  T.eq(out[3], "sat")
  T.eq(out[4], "bb", "line below untouched")

  T.eq(note, "Fixed 'teh' -> 'the'.", "the explanation went to the float, not the buffer")

  local entry = history.list()[1]
  T.eq(entry.op, "replace")
  T.ok(entry.label:find("%[fix%]"), "labelled as a fix")
  T.ok(entry.label:find("tidy", 1, true), "names the skill")
  T.eq(cache.get(entry.cache_key), "Fixed 'teh' -> 'the'.", "cached for re-open")
  T.eq(entry.start_row, 2)
  T.eq(entry.end_row, 3)

  local ns = vim.api.nvim_get_namespaces()["gerty.translated"]
  local buf = vim.api.nvim_get_current_buf()
  T.ok(
    #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) >= 2,
    "the corrected lines get the persistent sign"
  )
end)

T.test("a chat reply that omits the explanation field is a plain replace", function()
  setup_with_skill()
  history.clear()
  local out, note = replace_capturing(
    { "aa", "teh cat", "sat", "bb" },
    2,
    3,
    "/tidy fix it",
    { replacement = "the cat\nsat" } -- endpoint ignored the schema's 2nd field
  )
  T.eq(out[2], "the cat")
  T.eq(out[3], "sat")
  T.eq(note, nil, "no float without an explanation")
  T.eq(#history.list(), 0, "and nothing recorded")
end)

T.test("replace_explain = false closes the channel even with a skill", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/tidy", "p")
  local f = assert(io.open(dir .. "/tidy/SKILL.md", "w"))
  f:write("# tidy\n\nClean it up.\n")
  f:close()
  gerty.setup({
    providers = { ["local"] = { type = "lmstudio", models = { "a-local-model" } } },
    skills = { dir },
    replace_explain = false,
  })
  history.clear()

  local out, note, asked = replace_capturing(
    { "aa", "teh cat", "sat", "bb" },
    2,
    3,
    "/tidy fix it",
    { replacement = "the cat\nsat" }
  )
  T.eq(asked, false, "the grammar goes back to one field")
  T.eq(out[2], "the cat", "the edit still lands")
  T.eq(note, nil, "no float")
  T.eq(#history.list(), 0, "and nothing recorded")
end)

T.test("the explanation float does not steal the cursor", function()
  setup_with_skill()
  history.clear()

  -- the real float.show this time -- the point of the test is where the
  -- cursor ends up, which a stub cannot tell us
  local jobs = require("gerty.jobs")
  local orig_spawn = jobs.spawn
  jobs.spawn = function(_, opts)
    vim.schedule(function()
      opts.on_exit({
        status = "ok",
        output = T.chat_response(vim.json.encode({
          replacement = "the cat\nsat",
          explanation = "Fixed 'teh' -> 'the'.",
        })),
      })
    end)
    return 1
  end

  local buf = T.buffer_with_selection({ "aa", "teh cat", "sat", "bb" }, 2, 3)
  local edit_win = vim.api.nvim_get_current_win()
  local done = false
  local orig_set = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(...)
    done = true
    return orig_set(...)
  end
  gerty.replace({ instruction = "/tidy fix it" })
  T.wait_for(function() return done end)
  vim.wait(50)
  vim.api.nvim_buf_set_lines = orig_set
  jobs.spawn = orig_spawn

  T.eq(
    vim.api.nvim_get_current_win(),
    edit_win,
    "an edit op must leave you in the buffer you were editing"
  )
  T.eq(vim.api.nvim_get_current_buf(), buf)
  -- and the note really was shown, in some other window
  local shown = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= edit_win then
      local text =
        table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
      shown = shown or text:find("Fixed 'teh'", 1, true) ~= nil
    end
  end
  T.ok(shown, "the explanation float did not open at all")
end)

T.test("the explanation float survives the edit's own cursor move", function()
  -- A replacement shorter than the line under the cursor clamps the cursor,
  -- and Neovim reports that as CursorMoved on a later main-loop pass -- after
  -- the float has armed its dismiss. `nvim -l` never runs that pass, so fire
  -- the event by hand, from where the edit left things.
  local float = require("gerty.float")
  local buf = T.buffer_with_selection({ "aa", "a much longer line here" }, 2, 2)
  local edit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(edit_win, { 2, 20 })
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "short" })

  local win = float.show("t", "Fixed it.", { focus = false })
  vim.wait(20)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  T.ok(vim.api.nvim_win_is_valid(win), "the edit's own clamp closed the float")

  vim.api.nvim_win_set_cursor(edit_win, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  T.ok(not vim.api.nvim_win_is_valid(win), "a real cursor move should dismiss it")
end)

T.test("no skill means the request does not ask for an explanation", function()
  setup()
  history.clear()
  local _, note, asked = replace_capturing(
    { "aa", "x = 1", "y = 2", "bb" },
    2,
    3,
    "rename x to total",
    { replacement = "total = 1\ny = 2" }
  )
  T.eq(asked, false, "a plain replace grammar has one field")
  T.eq(note, nil)
  T.eq(#history.list(), 0)
end)

T.test("a whitespace-only explanation shows no float", function()
  setup_with_skill()
  history.clear()
  local _, note = replace_capturing(
    { "aa", "teh", "x", "bb" },
    2,
    3,
    "/tidy fix",
    { replacement = "the\nx", explanation = "   \n" }
  )
  T.eq(note, nil, "trimmed-empty explanations are dropped")
  T.eq(#history.list(), 0)
end)

T.test("a fence is stripped from the replacement field, not the explanation", function()
  setup_with_skill()
  history.clear()
  local out, note = replace_capturing(
    { "aa", "teh", "x", "bb" },
    2,
    3,
    "/tidy fix",
    { replacement = "```\nthe\nx\n```", explanation = "lowercased the typo" }
  )
  T.eq(out[2], "the", "the whole-answer fence around the code is removed")
  T.eq(out[3], "x")
  T.eq(out[4], "bb")
  T.eq(note, "lowercased the typo")
end)

T.test("on an agentic provider the note comes from stdout, not a delimiter", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/tidy", "p")
  local f = assert(io.open(dir .. "/tidy/SKILL.md", "w"))
  f:write("# tidy\n\nClean it up.\n")
  f:close()
  gerty.setup({
    providers = {
      cli = {
        type = {
          name = "cli",
          transport = "cli",
          capabilities = { agentic = true },
          build_command = function() return { "true" } end,
        },
      },
    },
    default = "cli",
    skills = { dir },
  })
  history.clear()

  local jobs = require("gerty.jobs")
  local float = require("gerty.float")
  local orig_spawn, orig_show = jobs.spawn, float.show
  local note, had_sentinel
  float.show = function(_, text) note = text; return 1 end
  jobs.spawn = function(cmd, opts)
    local prompt_text = cmd[#cmd]
    had_sentinel = prompt_text:match("<<<GERTY%-NOTES") ~= nil
    local path = prompt_text:match("file at (%S+) %-%-")
    vim.fn.writefile({ "The cat sat.", "It ran." }, path)
    vim.schedule(function()
      opts.on_exit({ status = "ok", output = "- capitalised 'the'\n- fixed 'teh'" })
    end)
    return 1
  end

  local buf = T.buffer_with_selection({ "a", "teh cat sat", "it ran", "b" }, 2, 3)
  local done = false
  local orig_set = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(...) done = true; return orig_set(...) end
  gerty.replace({ instruction = "/tidy fix" })
  T.wait_for(function() return done end)
  vim.api.nvim_buf_set_lines = orig_set
  jobs.spawn, float.show = orig_spawn, orig_show

  T.eq(had_sentinel, false, "the agentic prompt asks for a reply, not a delimiter")
  T.eq(vim.api.nvim_buf_get_lines(buf, 1, 3, false)[1], "The cat sat.")
  T.eq(note, "- capitalised 'the'\n- fixed 'teh'", "stdout became the note")
  T.eq(history.list()[1].op, "replace")
  T.eq(cache.get(history.list()[1].cache_key), "- capitalised 'the'\n- fixed 'teh'")
end)

T.test("agentic: empty stdout means no float", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/tidy", "p")
  local f = assert(io.open(dir .. "/tidy/SKILL.md", "w"))
  f:write("# tidy\n\nClean.\n")
  f:close()
  gerty.setup({
    providers = {
      cli = {
        type = {
          name = "cli",
          transport = "cli",
          capabilities = { agentic = true },
          build_command = function() return { "true" } end,
        },
      },
    },
    default = "cli",
    skills = { dir },
  })
  history.clear()

  local jobs = require("gerty.jobs")
  local float = require("gerty.float")
  local orig_spawn, orig_show = jobs.spawn, float.show
  local note
  float.show = function(_, t) note = t; return 1 end
  jobs.spawn = function(cmd, opts)
    local path = cmd[#cmd]:match("file at (%S+) %-%-")
    vim.fn.writefile({ "clean" }, path)
    vim.schedule(function() opts.on_exit({ status = "ok", output = "  \n" }) end)
    return 1
  end
  local buf = T.buffer_with_selection({ "a", "dirty", "b" }, 2, 2)
  local done = false
  local orig_set = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(...) done = true; return orig_set(...) end
  gerty.replace({ instruction = "/tidy fix" })
  T.wait_for(function() return done end)
  vim.api.nvim_buf_set_lines = orig_set
  jobs.spawn, float.show = orig_spawn, orig_show

  T.eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "clean", "the edit still lands")
  T.eq(note, nil)
  T.eq(#history.list(), 0)
end)
