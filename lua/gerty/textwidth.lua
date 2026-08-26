--- Shared by float.lua and hint.lua: how many screen rows `lines` will
--- occupy once wrapped at `width` -- `#lines` alone (a raw newline count)
--- badly undercounts prose, since one logical line can be several wrapped
--- rows once it hits the window edge.

local M = {}

--- @param lines string[]
--- @param width number
--- @return number
function M.wrapped_height(lines, width)
  local total = 0
  for _, line in ipairs(lines) do
    total = total + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return total
end

return M
