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
  -- Scheduled a tick late so the buffer edit that produced this float does not
  -- immediately dismiss it, and guarded so moving around *inside* the float
  -- (after a deliberate `<C-w>w`) does not either.
  if not focus then
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      vim.api.nvim_create_autocmd(
        { "CursorMoved", "CursorMovedI", "InsertEnter" },
        {
          callback = function()
            if not vim.api.nvim_win_is_valid(win) then
              return true
            end
            if vim.api.nvim_get_current_win() == win then
              return
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
