--- Shows a spinner + the last line of AI output as virtual text above (or
--- below) a buffer line, so you can keep editing elsewhere while a request
--- runs. Also provides a dim highlight to mark a range as "about to be
--- replaced."
---
--- Every entry point tolerates the buffer being gone. "Keep editing while it
--- runs" includes closing the file you started from, and a timer that is still
--- ticking when that happens must go quiet rather than throw a traceback into
--- the message area on every frame.

local ns = vim.api.nvim_create_namespace("gerty.status")
local dim_ns = vim.api.nvim_create_namespace("gerty.status.dim")
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- @class gerty.Spinner
--- @field buf number
--- @field id number
--- @field label string
--- @field last_line string|nil
--- @field frame number
--- @field running boolean
--- @field interval number
--- @field above boolean
local Spinner = {}
Spinner.__index = Spinner

--- @param buf number
--- @param line number 0-indexed line to anchor the virtual text to
--- @param label string
--- @param interval number|nil ms between frames
--- @param above boolean|nil place the virtual text above `line` (default) or below it
--- @return gerty.Spinner
function Spinner.attach(buf, line, label, interval, above)
  local self = setmetatable({}, Spinner)
  self.buf = buf
  self.label = label
  self.frame = 0
  self.interval = interval or 120
  self.above = above == nil or above

  -- an already-invalid buffer yields an inert spinner rather than an error:
  -- callers attach before they send, and a caller should not have to decide
  -- whether showing progress is safe
  if not vim.api.nvim_buf_is_valid(buf) then
    self.running = false
    return self
  end

  self.running = true
  self.id = vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {})
  self:_render()
  self:_tick()
  return self
end

function Spinner:_render()
  -- the buffer can be wiped mid-request; stop rather than throw once per frame
  if self.id == nil or not vim.api.nvim_buf_is_valid(self.buf) then
    self.running = false
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(self.buf, ns, self.id, {})
  if #pos == 0 then
    self.running = false
    return
  end

  self.frame = self.frame % #frames + 1
  local virt_lines = { { { frames[self.frame] .. " " .. self.label, "Comment" } } }
  if self.last_line then
    table.insert(virt_lines, { { self.last_line, "Comment" } })
  end

  vim.api.nvim_buf_set_extmark(self.buf, ns, pos[1], pos[2], {
    id = self.id,
    virt_lines = virt_lines,
    virt_lines_above = self.above,
  })
end

function Spinner:_tick()
  if not self.running then
    return
  end
  vim.defer_fn(function()
    if not self.running then
      return
    end
    self:_render()
    self:_tick()
  end, self.interval)
end

--- @param line string most recent line of AI stdout to display
function Spinner:push(line)
  self.last_line = line
end

--- Returns the current 0-indexed row of the anchor, or nil if it was deleted
--- (e.g. the user deleted the surrounding text while the request was running).
--- @return number|nil
function Spinner:row()
  if self.id == nil or not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(self.buf, ns, self.id, {})
  if #pos == 0 then
    return nil
  end
  return pos[1]
end

function Spinner:stop()
  self.running = false
  if self.id ~= nil then
    pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, self.id)
  end
end

--- Dims a line range to mark it as "about to be replaced." Tracks edits
--- inside the range the same way an extmark does.
--- @param buf number
--- @param start_row number 0-indexed, inclusive
--- @param end_row number 0-indexed, inclusive
--- @return number|nil id pass to Spinner.undim to clear it; nil if the buffer
--- was already gone
function Spinner.dim_range(buf, start_row, end_row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return vim.api.nvim_buf_set_extmark(buf, dim_ns, start_row, 0, {
    end_row = end_row + 1,
    end_col = 0,
    hl_group = "Comment",
    hl_eol = true,
    priority = 100,
  })
end

--- @param buf number
--- @param id number|nil no-op when dim_range found the buffer already gone
function Spinner.undim(buf, id)
  if id == nil then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, dim_ns, id)
end

return Spinner
