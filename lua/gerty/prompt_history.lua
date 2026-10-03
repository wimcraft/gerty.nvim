--- Persistent, operation-scoped input history for the two interactive code
--- prompts. This deliberately does not share gerty.history: that module points
--- at cached model answers and is session-only, while these are the exact words
--- a user typed and must survive a restart.

local M = {}

local OPS = { replace = true, explain = true }

M.MAX_ENTRIES = 200

local entries
local path_override

---@return { version: integer, replace: string[], explain: string[] }
local function empty()
  return { version = 1, replace = {}, explain = {} }
end

---@return string
local function path()
  return path_override
    or vim.fs.joinpath(vim.fn.stdpath("data"), "gerty", "prompt-history.json")
end

---@param value any
---@return boolean
local function valid(value)
  if type(value) ~= "table" or value.version ~= 1 then
    return false
  end
  for op in pairs(OPS) do
    if type(value[op]) ~= "table" then
      return false
    end
    for _, instruction in ipairs(value[op]) do
      if type(instruction) ~= "string" then
        return false
      end
    end
  end
  return true
end

local function load()
  if entries then
    return
  end

  local read_ok, lines = pcall(vim.fn.readfile, path())
  if not read_ok then
    entries = empty()
    return
  end

  local decode_ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  entries = decode_ok and valid(value) and value or empty()
end

local function save()
  local target = path()
  local parent = vim.fn.fnamemodify(target, ":h")
  local temp = target .. "." .. vim.uv.os_getpid() .. ".tmp"
  local encoded_ok, encoded = pcall(vim.json.encode, entries)
  if not encoded_ok then
    return
  end

  local ok = pcall(function()
    assert(vim.fn.mkdir(parent, "p") > 0 or vim.fn.isdirectory(parent) == 1)
    vim.fn.writefile({ encoded }, temp)
    assert(vim.uv.fs_rename(temp, target))
  end)
  if not ok then
    pcall(vim.fn.delete, temp)
  end
end

---@param op "replace"|"explain"
---@return string[]
function M.list(op)
  assert(OPS[op], "gerty: prompt history has no operation '" .. tostring(op) .. "'")
  load()
  return vim.deepcopy(entries[op])
end

---@param op "replace"|"explain"
---@param instruction string
function M.record(op, instruction)
  assert(OPS[op], "gerty: prompt history has no operation '" .. tostring(op) .. "'")
  assert(type(instruction) == "string", "gerty: prompt history instruction must be a string")
  if vim.trim(instruction) == "" then
    return
  end

  load()
  local list = entries[op]
  for i = #list, 1, -1 do
    if list[i] == instruction then
      table.remove(list, i)
    end
  end
  table.insert(list, 1, instruction)
  for i = #list, M.MAX_ENTRIES + 1, -1 do
    list[i] = nil
  end
  save()
end

--- Test-only storage isolation. The plugin's public API intentionally exposes
--- no history-management commands.
---@param test_path string|nil
---@return string|nil previous_path
function M._set_path_for_test(test_path)
  local previous_path = path_override
  path_override = test_path
  entries = nil
  return previous_path
end

return M
