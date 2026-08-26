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
--- @param title string
--- @param text string
--- @return number|nil win nil if there was nothing to show
function M.show(title, text)
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

  local win = vim.api.nvim_open_win(buf, true, {
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

  return win
end

return M
