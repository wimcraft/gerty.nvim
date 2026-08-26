--- Most-recent-first list of completed translate/gloss/word lookups, so you
--- can revisit one without re-running the request. Session-only, same as the
--- cache it points into -- gerty.cache holds the answer, this only remembers
--- what you asked and in what order.

local MAX_ENTRIES = 200

--- @class gerty.HistoryEntry
--- @field op "translate"|"gloss"|"word"
--- @field label string shown in the picker
--- @field cache_key string looked up in gerty.cache to get the answer
--- @field buf number|nil the buffer the selection came from
--- @field start_row number|nil 1-indexed, for jumping back
--- @field end_row number|nil 1-indexed

local M = {}

--- @type gerty.HistoryEntry[]
local entries = {}

--- Records a lookup, most-recent-first. Repeating the same lookup (same
--- cache_key) moves it to the front instead of duplicating it -- so looking
--- something up again, whether fresh or from cache, is what bumps it up.
--- @param entry gerty.HistoryEntry
function M.record(entry)
  for i = #entries, 1, -1 do
    if entries[i].cache_key == entry.cache_key then
      table.remove(entries, i)
    end
  end
  table.insert(entries, 1, entry)
  for i = #entries, MAX_ENTRIES + 1, -1 do
    entries[i] = nil
  end
end

--- @return gerty.HistoryEntry[]
function M.list()
  return entries
end

function M.clear()
  entries = {}
end

return M
