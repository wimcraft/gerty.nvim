--- Regression tests for the buffer being wiped while a request is in flight.
--- "Keep editing while it runs" includes closing the file you started from,
--- and a timer still ticking when that happens used to throw a traceback into
--- the message area on every frame, and leak the replace temp file.

local T = require("tests.helpers")
local gerty = require("gerty")
local Spinner = require("gerty.status")

T.test("a spinner on an already-dead buffer is inert, not an error", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  local spinner = Spinner.attach(buf, 0, "gerty: working", 10)
  T.eq(spinner.running, false)
  T.eq(spinner:row(), nil)
  spinner:stop()
  spinner:push("a line")
end)

T.test("a spinner survives its buffer being wiped underneath it", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
  local spinner = Spinner.attach(buf, 0, "gerty: working", 10)
  T.eq(spinner.running, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  spinner:_render()
  T.eq(spinner.running, false, "it must go quiet rather than throw once per frame")
  T.eq(spinner:row(), nil)
  spinner:stop()
end)

T.test("dimming a dead buffer is a no-op", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  local id = Spinner.dim_range(buf, 0, 1)
  T.eq(id, nil)
  Spinner.undim(buf, id)
end)

T.test("wiping the buffer mid-replace reports it and cleans up the temp file", function()
  gerty.setup({ providers = { pi = { models = { "m" } } } })
  local mock = T.mock_jobs()
  mock.delay = 120
  mock.reply = { status = "ok", output = "" }

  local buf = T.buffer_with_selection({ "local x = 1", "return x", "end" }, 1, 2)
  local messages = T.capture_notify(function()
    gerty.replace({ instruction = "rename x" })
    -- the temp path the model was told to write to is in the prompt argv
    local sent = mock.last.cmd[#mock.last.cmd]
    local tmp = sent:match("file at ([^%s]+)")
    T.ok(tmp, "replace should name a temp file for an agentic provider")

    vim.api.nvim_buf_delete(buf, { force = true })
    T.wait_for(function() return false end, 400)

    T.eq(vim.uv.fs_stat(tmp), nil, "the temp file leaked")
  end)

  local joined = table.concat(messages, " ")
  T.ok(
    joined:find("buffer was closed", 1, true),
    "expected a notification, got: " .. joined
  )
  T.unmock_jobs(mock)
end)

T.test("cancel_all resolves in-flight work as cancelled, not failed", function()
  gerty.setup({ providers = { pi = { models = { "m" } } } })
  local jobs = require("gerty.jobs")
  local seen
  local id = jobs.spawn({ "sleep", "5" }, {
    on_exit = function(result) seen = result.status end,
  })
  T.ok(id, "job started")
  jobs.cancel_all()
  T.wait_for(function() return seen ~= nil end)
  T.eq(seen, "cancelled")
  T.eq(jobs.count(), 0, "no jobs left in flight")
end)

T.test("a missing binary is reported, not thrown", function()
  local jobs = require("gerty.jobs")
  local seen
  jobs.spawn({ "gerty-no-such-binary-exists" }, {
    on_exit = function(result) seen = result end,
  })
  T.wait_for(function() return seen ~= nil end)
  T.eq(seen.status, "error")
  T.ok(seen.error and #seen.error > 0, "the failure carries a message")
end)

--- The three findings from the pre-publication audit. Each of these was a real
--- reproduced defect, so each gets a test that fails without its fix.

--- Runs replace against a delayed reply, letting `during` mutate the buffer
--- while the request is in flight.
--- @param lines string[]
--- @param during fun(buf: number)
--- @return string[] lines afterwards
--- @return string[] notifications
local function replace_interrupted_by(lines, during)
  gerty.setup({ providers = { lm = { type = "lmstudio", models = { "m" } } } })
  local mock = T.mock_jobs()
  mock.delay = 100
  mock.reply = {
    status = "ok",
    output = T.chat_response(vim.json.encode({ replacement = "NEW" })),
  }
  local buf = T.buffer_with_selection(lines, 2, 3)
  local messages = T.capture_notify(function()
    gerty.replace({ instruction = "x" })
    during(buf)
    T.wait_for(function() return false end, 400)
  end)
  T.unmock_jobs(mock)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false), messages
end

T.test("deleting the selection mid-request does not destroy the line below", function()
  local out, messages = replace_interrupted_by(
    { "above", "selected one", "selected two", "below" },
    function(buf)
      vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})
    end
  )
  -- extmarks RELOCATE to the deletion boundary rather than disappearing, so a
  -- "did the mark survive" check passes and the write lands on `below`
  T.ok(vim.tbl_contains(out, "below"), "`below` was destroyed: " .. vim.inspect(out))
  T.ok(not vim.tbl_contains(out, "NEW"), "the replacement must not be written anywhere")
  T.ok(#messages > 0, "the user must be told the replace was abandoned")
end)

T.test("editing the selection mid-request abandons the replace", function()
  local out = replace_interrupted_by(
    { "above", "selected one", "selected two", "below" },
    function(buf)
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "edited by hand" })
    end
  )
  T.ok(vim.tbl_contains(out, "edited by hand"), "the user's own edit must win")
  T.ok(not vim.tbl_contains(out, "NEW"), "the answer describes text that no longer exists")
end)

T.test("edits ABOVE the selection still let the replace land", function()
  local out = replace_interrupted_by(
    { "above", "selected one", "selected two", "below" },
    function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
    end
  )
  T.eq(table.concat(out, "|"), "inserted|above|NEW|below", "marks must follow edits above")
end)

T.test("an abandoned replace leaves no tracking extmarks behind", function()
  gerty.setup({ providers = { lm = { type = "lmstudio", models = { "m" } } } })
  local mock = T.mock_jobs()
  mock.delay = 30
  mock.reply = { status = "error", output = "", error = "boom" }
  local buf = T.buffer_with_selection({ "a", "b", "c" }, 2, 3)
  T.capture_notify(function()
    gerty.replace({ instruction = "x" })
    T.wait_for(function() return false end, 300)
  end)
  local ns = vim.api.nvim_get_namespaces()["gerty.marks"]
  T.eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0, "extmarks leaked")
  T.unmock_jobs(mock)
end)

T.test("a provider whose build_command throws does not strand the spinner", function()
  gerty.setup({
    providers = {
      boom = {
        type = {
          name = "boom",
          transport = "cli",
          capabilities = { agentic = true },
          build_command = function()
            error("build failed")
          end,
        },
        models = { "m" },
      },
    },
  })
  local buf = T.buffer_with_selection({ "a", "b", "c" }, 2, 3)
  local messages = T.capture_notify(function()
    gerty.replace({ instruction = "x" })
    T.wait_for(function() return false end, 300)
  end)
  local status_ns = vim.api.nvim_get_namespaces()["gerty.status"]
  local dim_ns = vim.api.nvim_get_namespaces()["gerty.status.dim"]
  T.eq(#vim.api.nvim_buf_get_extmarks(buf, status_ns, 0, -1, {}), 0, "spinner stranded")
  T.eq(#vim.api.nvim_buf_get_extmarks(buf, dim_ns, 0, -1, {}), 0, "dim highlight stranded")
  T.ok(
    table.concat(messages, " "):find("build failed", 1, true),
    "the failure must surface as a notification, not an exception"
  )
end)

T.test("a buffer wiped while the prompt is open is caught", function()
  -- replace() captures the buffer handle, then opens vim.ui.input. An async
  -- input UI (or an autocmd, or a timer) can wipe that buffer before the user
  -- submits, and the handle is stale by the time the callback runs.
  gerty.setup({ providers = { lm = { type = "lmstudio", models = { "m" } } } })
  local mock = T.mock_jobs()
  local submit
  local original = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    submit = on_confirm -- defer instead of answering immediately
  end

  local buf = T.buffer_with_selection({ "a", "b", "c" }, 2, 3)
  gerty.replace()
  vim.ui.input = original
  T.ok(submit, "the prompt should have opened")

  vim.api.nvim_buf_delete(buf, { force = true })
  local messages = T.capture_notify(function()
    submit("rename things")
  end)

  T.eq(mock.calls, 0, "nothing may be sent for a buffer that is gone")
  T.ok(
    table.concat(messages, " "):find("buffer is gone", 1, true),
    "expected a notification, got: " .. table.concat(messages, " ")
  )
  T.unmock_jobs(mock)
end)
