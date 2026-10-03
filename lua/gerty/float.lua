--- A scratch float for op output that is prose rather than code. Nothing
--- here writes to a real buffer -- closing the window discards everything.

local textwidth = require("gerty.textwidth")

local M = {}

--- @param text string
--- @return string[]
local function to_lines(text)
  local clean = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  clean = clean:gsub("%s+$", "")
  return vim.split(clean, "\n", { plain = true })
end

--- The cursor of `win` as Neovim will report it once it has settled: the
--- column clamped to the line the way normal mode clamps it. Right after a
--- buffer edit `nvim_win_get_cursor` can still hold a column past the end of a
--- line that just got shorter; the clamp only happens on the next main-loop
--- pass, and arrives as a `CursorMoved` of its own.
--- @param win number
--- @return integer[] { row, col }
local function settled_cursor(win)
  local pos = vim.api.nvim_win_get_cursor(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
    or ""
  local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  local max_col = insert and #line or math.max(#line - 1, 0)
  return { pos[1], math.min(pos[2], max_col) }
end

--- Opens a centred, bordered markdown float. `q` and `<Esc>` close it.
---
--- `opts.focus = false` leaves the cursor where it was and dismisses the float
--- on the next cursor move, the way an LSP hover does. That is the right shape
--- when the float accompanies an action the user asked for rather than being
--- the answer they asked for -- `replace` puts its explanation here, and having
--- an edit yank the cursor out of the buffer is worse than missing the note.
--- @param title string
--- @param text string
--- @param opts { focus: boolean|nil }|nil
--- @return number|nil win nil if there was nothing to show
function M.show(title, text, opts)
  local focus = not (opts and opts.focus == false)
  local lines = to_lines(text)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, math.max(60, math.floor(vim.o.columns * 0.7)))
  local max_height = math.max(10, math.floor(vim.o.lines * 0.7))
  local height =
    math.max(3, math.min(max_height, textwidth.wrapped_height(lines, width)))

  local win = vim.api.nvim_open_win(buf, focus, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].cursorline = false

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end

  -- An unfocused float has nowhere to send `q` to, so it needs its own way
  -- out: the next cursor move in the window that kept focus closes it.
  --
  -- "Next move" has to mean a move *away from where the edit left the
  -- cursor*. The edit that produced this float can shift or clamp the cursor
  -- (a replacement shorter than what it replaced), and Neovim only reports
  -- that as `CursorMoved` on a later pass of its main loop -- after any
  -- scheduled tick. Listening from a tick late is therefore not enough: the
  -- float would catch the edit's own move and close before it is ever seen.
  -- So the listener remembers the settled position and ignores events that
  -- still sit on it. It is also guarded so moving around *inside* the float
  -- (after a deliberate `<C-w>w`) does not dismiss it.
  if not focus then
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      local anchor_win = vim.api.nvim_get_current_win()
      local anchor = settled_cursor(anchor_win)
      vim.api.nvim_create_autocmd(
        { "CursorMoved", "CursorMovedI", "InsertEnter" },
        {
          callback = function(ev)
            if not vim.api.nvim_win_is_valid(win) then
              return true
            end
            local current = vim.api.nvim_get_current_win()
            if current == win then
              return
            end
            if ev.event ~= "InsertEnter" and current == anchor_win then
              local now = settled_cursor(current)
              if now[1] == anchor[1] and now[2] == anchor[2] then
                return
              end
            end
            vim.api.nvim_win_close(win, true)
            return true
          end,
        }
      )
    end)
  end

  return win
end

return M
