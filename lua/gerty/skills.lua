--- #name in a prompt injects the contents of <dir>/name/SKILL.md as extra
--- context. Directories are scanned once at setup(); call refresh() to
--- pick up newly added skills without restarting.

local M = {}

--- @param dirs string[]
--- @return table<string, string> name -> absolute path to SKILL.md
function M.discover(dirs)
  local map = {}
  for _, dir in ipairs(dirs) do
    local expanded = vim.fn.expand(dir)
    for _, path in ipairs(vim.fn.globpath(expanded, "*/SKILL.md", false, true)) do
      local name = vim.fn.fnamemodify(path, ":h:t")
      map[name] = path
    end
  end
  return map
end

--- @param prompt string
--- @param skill_map table<string, string>
--- @return string[] names of skills referenced
--- @return string[] their SKILL.md contents, wrapped for prompt injection
function M.resolve(prompt, skill_map)
  local names = {}
  local contents = {}
  local seen = {}

  for word in prompt:gmatch("#(%S+)") do
    if not seen[word] then
      seen[word] = true
      local path = skill_map[word]
      if path then
        local file = io.open(path, "r")
        if file then
          local body = file:read("*a")
          file:close()
          table.insert(names, word)
          table.insert(
            contents,
            string.format("<skill name=%q>\n%s\n</skill>", word, body)
          )
        end
      end
    end
  end

  return names, contents
end

return M
