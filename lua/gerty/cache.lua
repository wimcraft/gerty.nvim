--- In-memory cache for language-op results (translate/gloss/word), keyed on
--- everything that affects the answer: selected text, surrounding context,
--- language pair, and which agent/model produced it. Session-only -- cleared
--- on restart, nothing written to disk. Exists so re-reading a paragraph you
--- already looked up is instant instead of a fresh request every time.

local M = {}

--- @type table<string, string>
local store = {}

--- Builds a stable key from parts that can't collide with each other: joined
--- with U+001E (record separator), a byte that never appears in prose.
--- @param parts (string|number|nil)[]
--- @return string
function M.key(parts)
  local out = {}
  for i, part in ipairs(parts) do
    out[i] = tostring(part)
  end
  return table.concat(out, "\30")
end

--- @param key string
--- @return string|nil
function M.get(key)
  return store[key]
end

--- @param key string
--- @param value string
function M.set(key, value)
  store[key] = value
end

--- Drops every cached entry.
function M.clear()
  store = {}
end

return M
