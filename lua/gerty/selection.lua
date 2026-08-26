--- Visual-selection capture for the language ops.
---
--- Deliberately built on Neovim's own `getregion()` rather than walking UTF-8
--- bytes by hand: it already handles charwise/linewise/blockwise, inclusive
--- vs. exclusive `'selection'`, multibyte boundaries and backwards selections,
--- and it treats a blockwise selection as a block instead of quietly widening
--- it to whole lines.
---
--- Used by `translate`/`gloss` only. `replace` stays line-based on purpose --
--- rewriting code is a different contract from quoting prose (see
--- `gerty_nvim-ln9`).

--- @class gerty.Selection
--- @field buf number
--- @field mode string "v", "V" or "\22"
--- @field anchor number[] getpos() tuple for the selection anchor
--- @field cursor number[] getpos() tuple for the other end
--- @field start_row number 1-indexed inclusive
--- @field end_row number 1-indexed inclusive
--- @field text string the selected text, lines joined with "\n"

local M = {}

--- @param mode string
--- @return boolean
local function is_visual(mode)
  return mode == "v" or mode == "V" or mode == "\22"
end

--- Reads the *live* anchor (`v`) and cursor (`.`) while still in visual mode
--- -- the `'<`/`'>` marks only update after visual mode exits, so inside a
--- visual-mode mapping they still hold the previous selection. Falls back to
--- the marks when called from anywhere else (a command line, a normal-mode
--- mapping after the fact), which is why `:lua require('gerty').translate()`
--- also works.
---
--- @return gerty.Selection|nil nil when there is no selection to read
function M.capture_visual()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local anchor, cursor, exclusive

  if is_visual(mode) then
    anchor, cursor = vim.fn.getpos("v"), vim.fn.getpos(".")
    exclusive = vim.o.selection == "exclusive"
  else
    mode = vim.fn.visualmode()
    if not is_visual(mode) then
      return nil
    end
    -- '> is already the inclusive last character of the previous selection
    anchor, cursor = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    exclusive = false
  end

  local ok, lines = pcall(vim.fn.getregion, anchor, cursor, {
    type = mode,
    exclusive = exclusive,
  })
  if not ok or type(lines) ~= "table" then
    return nil
  end

  local start_row = math.min(anchor[2], cursor[2])
  local end_row = math.max(anchor[2], cursor[2])

  return {
    buf = buf,
    mode = mode,
    anchor = anchor,
    cursor = cursor,
    start_row = start_row,
    end_row = end_row,
    text = table.concat(lines, "\n"),
  }
end

--- Leaves visual mode immediately, so anything opened next (a float, a
--- `vim.ui.input` prompt) isn't fighting an active selection. Must be called
--- *after* capture_visual().
function M.exit_visual()
  if not is_visual(vim.fn.mode()) then
    return
  end
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
    "x",
    false
  )
end

--- The lines around the selection, for disambiguation only -- the ops that
--- use this tell the model in so many words not to act on them.
--- @param sel gerty.Selection
--- @param context_lines number
--- @return string before
--- @return string after
function M.context(sel, context_lines)
  if not vim.api.nvim_buf_is_valid(sel.buf) then
    return "", ""
  end
  local total = vim.api.nvim_buf_line_count(sel.buf)
  local before = vim.api.nvim_buf_get_lines(
    sel.buf,
    math.max(0, sel.start_row - 1 - context_lines),
    sel.start_row - 1,
    false
  )
  local after = vim.api.nvim_buf_get_lines(
    sel.buf,
    math.min(sel.end_row, total),
    math.min(total, sel.end_row + context_lines),
    false
  )
  return table.concat(before, "\n"), table.concat(after, "\n")
end

return M
