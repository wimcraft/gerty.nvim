--- /name in a prompt injects the contents of <dir>/name/SKILL.md as extra
--- context. Directories are scanned once at setup(); call refresh() to
--- pick up newly added skills without restarting.

local prompt_tokens = require("gerty.prompt_tokens")

local M = {}

--- summary() is called for every skill each time the reference card opens, and
--- the answer only changes when a SKILL.md does. Memoised on path + mtime so a
--- card with a dozen skills is not a dozen file reads per prompt, while an
--- edited skill still re-reads.
--- @type table<string, { mtime: number, text: string|nil }>
local summary_cache = {}

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

--- Cut to a display width, not a character count: `strcharpart(s, 0, 99)` on
--- CJK is 198 cells, and this plugin's whole reason for existing is text in
--- other languages.
--- @param text string
--- @param width number
--- @return string
local function truncate_to_width(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  -- one character at a time: there is no width-indexed cut in vimscript, and
  -- a summary is one line, so the loop costs nothing worth avoiding
  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. char) > width - 1 then
      break
    end
    out = out .. char
  end
  return out .. "…"
end

--- A one-line gloss of a skill for the reference card: the first Markdown
--- heading's text, else the first non-blank line, stripped of inline Markdown
--- and capped. A heading that just repeats the skill's own name is skipped --
--- `# grammar` tells the reader nothing.
--- @param path string absolute path to a SKILL.md
--- @param name string|nil the skill's name, so a name-echoing heading is ignored
--- @return string|nil
function M.summary(path, name)
  local mtime = vim.fn.getftime(path)
  local hit = summary_cache[path]
  if hit and hit.mtime == mtime then
    return hit.text
  end

  local file = io.open(path, "r")
  if not file then
    return nil
  end
  -- the first line that carries meaning, in document order: a heading, or a
  -- line of prose -- whichever comes first. A heading that only repeats the
  -- skill's own name (`# grammar`) is skipped so the gloss says something new.
  local text
  for line in file:lines() do
    local h = line:match("^#+%s+(.+)$")
    if h then
      h = (vim.trim(h):gsub("[`*_]", ""))
      if not name or h:lower() ~= name:lower() then
        text = h
        break
      end
    elseif vim.trim(line) ~= "" then
      text = (vim.trim(line):gsub("[`*_]", ""))
      break
    end
  end
  file:close()

  local result = text and truncate_to_width(text, 100) or nil
  summary_cache[path] = { mtime = mtime, text = result }
  return result
end

--- @param prompt string
--- @param skill_map table<string, string>
--- @return string[] names skills referenced and found, first-seen order
--- @return string[] contents their SKILL.md bodies, wrapped for prompt injection
--- @return string[] unknown `/name` tokens that matched no discovered skill (deduped)
function M.resolve(prompt, skill_map)
  local names = {}
  local contents = {}
  local unknown = {}
  local seen = {}

  local tokens = prompt_tokens.scan(prompt, {
    providers = {},
    provider_names = {},
    skill_map = skill_map,
  })

  for _, tok in ipairs(tokens) do
    if tok.kind == "skill" and not seen[tok.name] then
      seen[tok.name] = true
      local path = skill_map[tok.name]
      if not path then
        unknown[#unknown + 1] = tok.name
      else
        local file = io.open(path, "r")
        if file then
          local body = file:read("*a")
          file:close()
          table.insert(names, tok.name)
          table.insert(
            contents,
            string.format("<skill name=%q>\n%s\n</skill>", tok.name, body)
          )
        end
      end
    end
  end

  return names, contents, unknown
end

return M
