--- The one place that decides what a `$provider` / `/skill` token IS and
--- whether it currently resolves. The prompt highlight handler, the `<Tab>`
--- completer and `skills.resolve()` all read from here, so the colour on
--- screen, the completion list and what actually gets injected can never
--- drift apart.
---
--- Offsets are 0-indexed byte positions, `from` inclusive and `to` exclusive
--- -- the shape `vim.fn.input`'s highlight handler wants (see
--- `:help input()-highlight`).

local M = {}

--- @class gerty.PromptToken
--- @field kind "provider"|"skill"
--- @field name string the text after the sigil
--- @field from number 0-indexed byte offset of the sigil
--- @field to number 0-indexed byte offset one past the token
--- @field known boolean does it resolve against the config passed in?
--- @field resolved string|nil provider alias a `$N`/`$alias` maps to

--- @class gerty.TokenContext
--- @field providers table<string, any> alias -> provider (only keys are read)
--- @field provider_names string[] sorted aliases, for `$N`
--- @field skill_map table<string, string> skill name -> SKILL.md path

--- @param prompt string
--- @param ctx gerty.TokenContext
--- @return gerty.PromptToken[] ordered by `from`, non-overlapping
function M.scan(prompt, ctx)
  local tokens = {}

  -- provider: only a leading `$token`, mirroring init.lua's split_alias().
  -- `%S+` so the highlighted span is exactly what split_alias() would strip.
  local p_start, p_name, p_after = prompt:match("^%s*()%$(%S+)()")
  if p_name then
    local resolved
    local index = p_name:match("^%d+$") and tonumber(p_name)
    if index then
      resolved = ctx.provider_names[index]
    elseif ctx.providers[p_name] then
      resolved = p_name
    end
    tokens[#tokens + 1] = {
      kind = "provider",
      name = p_name,
      from = p_start - 1,
      to = p_after - 1,
      known = resolved ~= nil,
      resolved = resolved,
    }
  end

  -- skill: `/name` anywhere in the prompt, but the `/` must sit at the start
  -- of the line or straight after whitespace -- so `and/or` and `src/foo.lua`
  -- are left alone. The name is `[%w][%w._-]*` rather than `%S+` so trailing
  -- punctuation (`/grammar,`) doesn't turn a real reference into a miss.
  for s_start, s_name, s_after in prompt:gmatch("()/([%w][%w._-]*)()") do
    local prev = s_start > 1 and prompt:sub(s_start - 1, s_start - 1) or ""
    if prev == "" or prev:match("%s") then
      tokens[#tokens + 1] = {
        kind = "skill",
        name = s_name,
        from = s_start - 1,
        to = s_after - 1,
        known = ctx.skill_map[s_name] ~= nil,
      }
    end
  end

  table.sort(tokens, function(a, b)
    return a.from < b.from
  end)
  return tokens
end

return M
