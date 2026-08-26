--- One owner for every subprocess gerty starts: provider CLIs, `curl` for
--- HTTP providers, and the dictionary binary. There is exactly one monotonic
--- ID space, so the ids handed back can safely key shared UI state in
--- init.lua -- two independent counters (one per transport) would hand out
--- the same number twice and overwrite each other's spinners.
---
--- Every job completes exactly once. Cancelling resolves it immediately with
--- `status = "cancelled"`, and the process's real exit is ignored when it
--- eventually lands -- so a cancelled op reports itself as cancelled rather
--- than as whatever half-written garbage the killed process left behind.

--- @class gerty.JobResult
--- @field status "ok"|"error"|"cancelled"
--- @field output string everything the process wrote to stdout
--- @field error string|nil set when status == "error"

--- @class gerty.JobOpts
--- @field stdin string|nil written to the process's stdin, which is then closed
--- @field on_stdout fun(line: string)|nil called per line of stdout
--- @field on_exit fun(result: gerty.JobResult)|nil called exactly once

--- @class gerty.Job
--- @field proc vim.SystemObj|nil
--- @field done boolean
--- @field finish fun(result: gerty.JobResult)

--- @type table<number, gerty.Job>
local running = {}
local next_id = 0

local M = {}

--- Because we install a `stdout` handler, `vim.system` never populates
--- `obj.stdout` -- so we accumulate the chunks ourselves and hand the whole
--- thing back in the result. Ops that only write to a temp file (`replace`)
--- ignore it; ops whose answer *is* the stdout (`explain`, `translate`,
--- `word`) need it.
---
--- @param cmd string[] the complete argv, prompt included
--- @param opts gerty.JobOpts
--- @return number id
function M.spawn(cmd, opts)
  next_id = next_id + 1
  local id = next_id

  local chunks = {}
  --- @type gerty.Job
  local job = { done = false, finish = function(_) end }

  job.finish = function(result)
    if job.done then
      return
    end
    job.done = true
    running[id] = nil
    if opts.on_exit then
      opts.on_exit(result)
    end
  end

  running[id] = job

  local spawned, proc = pcall(vim.system, cmd, {
    text = true,
    stdin = opts.stdin,
    stdout = vim.schedule_wrap(function(err, data)
      if err or not data or job.done then
        return
      end
      table.insert(chunks, data)
      if opts.on_stdout then
        for _, line in ipairs(vim.split(data, "\n", { trimempty = true })) do
          opts.on_stdout(line)
        end
      end
    end),
  }, vim.schedule_wrap(function(obj)
    local output = table.concat(chunks)
    if obj.code == 0 then
      job.finish({ status = "ok", output = output })
      return
    end
    local err = obj.stderr
    if not err or err == "" then
      err = string.format("%s exited with code %d", cmd[1], obj.code)
    end
    job.finish({ status = "error", output = output, error = vim.trim(err) })
  end))

  -- vim.system throws when the binary doesn't exist; surface that the same
  -- way as any other failure instead of tearing down the caller's stack
  if not spawned then
    vim.schedule(function()
      job.finish({ status = "error", output = "", error = tostring(proc) })
    end)
    return id
  end

  job.proc = proc
  return id
end

--- A job that never started. Command construction can fail before there is
--- anything to spawn (a custom `build_command` that throws), and the caller
--- has already put a spinner up by then -- so that has to arrive as a normal
--- failed completion rather than as an exception, or the UI it attached is
--- stranded with no id to cancel.
--- @param message string
--- @param on_exit fun(result: gerty.JobResult)|nil
--- @return number id
function M.fail(message, on_exit)
  next_id = next_id + 1
  local id = next_id
  vim.schedule(function()
    if on_exit then
      on_exit({ status = "error", output = "", error = message })
    end
  end)
  return id
end

--- Resolves the job as "cancelled" right now, then SIGTERMs the process. The
--- eventual real exit hits the `done` guard and is dropped.
--- @param id number
function M.cancel(id)
  local job = running[id]
  if not job then
    return
  end
  local proc = job.proc
  job.finish({ status = "cancelled", output = "" })
  if proc then
    pcall(function()
      proc:kill(15) -- SIGTERM
    end)
  end
end

--- Snapshots the ids first: cancelling mutates `running` from inside the
--- loop, which is not safe to do while iterating it directly.
function M.cancel_all()
  for _, id in ipairs(vim.tbl_keys(running)) do
    M.cancel(id)
  end
end

--- @return number how many jobs are still in flight (used by tests)
function M.count()
  return #vim.tbl_keys(running)
end

return M
