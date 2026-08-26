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
