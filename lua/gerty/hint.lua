--- A static reference card shown beside a `vim.ui.input()` prompt: which
--- agents can be named inline with `$alias`, which skills with `#name`.
---
--- Deliberately the cheap version of completion -- it never takes focus,
--- never intercepts a keystroke, and closes as soon as the input resolves.
--- Live completion would mean wiring `vim.ui.input`'s `completion=` machinery
--- and is a separate piece of work.

local textwidth = require("gerty.textwidth")

local ns = vim.api.nvim_create_namespace("gerty.hint")

local M = {}

--- A plain list of lines reads as a wall of text once it's several entries
--- long. Rather than teach every caller to build styled segments, this finds
--- the same few shapes automatically: a line ending in `:` is a section
--- header, a leading `$name`/`#name` token is what you'd actually type, and
--- any trailing `(...)`/`[...]` is metadata -- so it's the least important
--- part to read at a glance.
--- @param buf number
--- @param lines string[]
local function highlight(buf, lines)
  for i, line in ipairs(lines) do
    local row = i - 1
    if line:match(":%s*$") then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_col = #line,
        hl_group = "Title",
      })
    else
      local lead_start, lead_end = line:find("^%s*[%$#]%S+")
      if lead_start then
        vim.api.nvim_buf_set_extmark(buf, ns, row, lead_start - 1, {
          end_col = lead_end,
          hl_group = "Special",
        })
      end
      for match_start, match_end in line:gmatch("()%b()()") do
        vim.api.nvim_buf_set_extmark(buf, ns, row, match_start - 1, {
          end_col = match_end - 1,
          hl_group = "Comment",
        })
      end
      for match_start, match_end in line:gmatch("()%[[^%[%]]*%]()") do
        vim.api.nvim_buf_set_extmark(buf, ns, row, match_start - 1, {
          end_col = match_end - 1,
          hl_group = "Comment",
        })
      end
    end
  end
end

--- @param lines string[]
--- @return fun() closes the window; safe to call more than once, and safe if
--- the window is already gone
function M.open(lines)
  if #lines == 0 then
    return function() end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  highlight(buf, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- as wide as the editor allows, so wrapping is the exception rather than
  -- the rule -- but "Available agents: ..." grows with every configured
  -- agent's "model via provider [billing]" label, so it still needs to wrap
  -- (and the window still needs to be tall enough for that), not just get
  -- silently clipped at the window edge like it used to.
  local width = math.max(20, vim.o.columns - 4)
  local height = math.min(
    math.floor(vim.o.lines * 0.4),
    textwidth.wrapped_height(lines, width)
  )

  local opened, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "editor",
    width = width,
    height = height,
    -- just above the command line, where the prompt itself will appear
    row = math.max(0, vim.o.lines - height - 4),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
  })
  if not opened then
    -- the buffer exists already; `bufhidden = "wipe"` only fires for a buffer
    -- that was displayed, so nothing else will collect it
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return function() end
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  pcall(vim.cmd, "redraw")

  local closed = false
  return function()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

return M
