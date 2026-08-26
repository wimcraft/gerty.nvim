--- Minimal test harness. Deliberately dependency-free: gerty itself needs
--- nothing beyond Neovim, and a test suite that drags in plenary would make
--- contributing harder than the plugin is.

local T = {}

T.failures = {}
T.passed = 0
local current = "?"

--- @param name string
--- @param fn fun()
function T.test(name, fn)
  current = name
  -- a test that fails mid-way must not leave jobs.spawn mocked, or every test
  -- after it silently runs against the previous test's fake
  local pristine = require("gerty.jobs").spawn
  local ok, err = pcall(fn)
  require("gerty.jobs").spawn = pristine
  if ok then
    T.passed = T.passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    table.insert(T.failures, { name = name, err = tostring(err) })
    io.write("  FAIL " .. name .. "\n       " .. tostring(err) .. "\n")
  end
end

--- @param cond any
--- @param msg string|nil
function T.ok(cond, msg)
  if not cond then
    error(msg or "expected a truthy value", 2)
  end
end

--- @param got any
--- @param want any
--- @param what string|nil
function T.eq(got, want, what)
  if got ~= want then
    error(
      string.format(
        "%s: expected %s, got %s",
        what or "value",
        vim.inspect(want),
        vim.inspect(got)
      ),
      2
    )
  end
end

--- Asserts that `fn` raises, and that the message mentions `pattern`. Used for
--- every setup() validation case: the point of those asserts is the message,
--- so a test that only checked "it failed" would miss a regression that made
--- the message useless.
--- @param fn fun()
--- @param pattern string plain substring the error must contain
function T.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("expected an error mentioning " .. vim.inspect(pattern), 2)
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    error(
      string.format(
        "error did not mention %s\n       got: %s",
        vim.inspect(pattern),
        tostring(err)
      ),
      2
    )
  end
end

--- Replaces jobs.spawn so nothing is executed. Returns a table whose `last`
--- field holds the most recent { cmd, stdin }, plus a `reply` you can set to
--- have the fake job resolve with a given result.
--- @return table
function T.mock_jobs()
  local jobs = require("gerty.jobs")
  local mock = { last = nil, calls = 0, reply = nil, delay = 0 }
  mock.original = jobs.spawn
  jobs.spawn = function(cmd, opts)
    mock.calls = mock.calls + 1
    mock.last = { cmd = cmd, stdin = opts.stdin }
    if mock.reply then
      local reply = mock.reply
      if mock.delay > 0 then
        vim.defer_fn(function()
          opts.on_exit(reply)
        end, mock.delay)
      else
        vim.schedule(function()
          opts.on_exit(reply)
        end)
      end
    end
    return mock.calls
  end
  return mock
end

--- @param mock table
function T.unmock_jobs(mock)
  require("gerty.jobs").spawn = mock.original
end

--- An OpenAI-compatible response body wrapping `content`.
--- @param content string
--- @return string
function T.chat_response(content)
  return vim.json.encode({ choices = { { message = { content = content } } } })
end

--- Collects vim.notify output for the duration of `fn`.
--- @param fn fun()
--- @return string[] messages
function T.capture_notify(fn)
  local messages = {}
  local original = vim.notify
  vim.notify = function(msg)
    table.insert(messages, tostring(msg))
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err, 0)
  end
  return messages
end

--- A scratch buffer holding `lines`, made current, with the given range
--- selected linewise.
--- @param lines string[]
--- @param first number 1-indexed
--- @param last number 1-indexed
--- @return number buf
function T.buffer_with_selection(lines, first, last)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  vim.cmd("normal! V")
  if last > first then
    vim.cmd("normal! " .. (last - first) .. "j")
  end
  return buf
end

--- Blocks until `cond` is true or the timeout elapses. Never used to "wait a
--- bit" -- always waits on the condition the test actually cares about.
--- @param cond fun(): boolean
--- @param timeout number|nil ms
function T.wait_for(cond, timeout)
  vim.wait(timeout or 2000, cond, 10)
end

--- German fixtures. Written for this suite rather than taken from anything, so
--- the repository carries no third-party prose. The first one is
--- quote-initial on purpose: that is the shape that used to truncate.
T.de = {
  dialogue = '„Das ist meine Tasse!" Der Kellner stellte das Tablett ab und ging.',
  plain = "Der Bäcker öffnete die Tür und trat auf die Straße.",
  before = "Es hatte die ganze Nacht geregnet.\nDie Straße war noch nass.",
  after = "Ein Hund bellte irgendwo.\nEs roch nach frischem Brot.",
}

return T
