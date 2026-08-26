local config = require("gerty.config")
local skills = require("gerty.skills")
local prompt = require("gerty.prompt")
local jobs = require("gerty.jobs")
local transport = require("gerty.transport")
local selection = require("gerty.selection")
local cache = require("gerty.cache")
local history = require("gerty.history")
local hint = require("gerty.hint")
local Spinner = require("gerty.status")
local float = require("gerty.float")

local marks_ns = vim.api.nvim_create_namespace("gerty.marks")
--- Persistent sign marking a line a translate/gloss answer covered -- unlike
--- the dim highlight (which only shows while the request is in flight), this
--- stays after the float closes so scrolling past a paragraph shows at a
--- glance whether you've already looked it up.
local translated_ns = vim.api.nvim_create_namespace("gerty.translated")

local M = {}

--- @type gerty.Config|nil
local cfg
--- @type table<string, string>
local skill_map = {}
--- Keyed by the jobs.lua id, which is the single ID space every transport
--- draws from -- two counters would collide here and clobber each other's UI.
--- @type table<number, { spinner: gerty.Spinner }>
local active = {}

--- The one op that genuinely cannot run on a chat-only provider. `ask` is
--- *defined* as "edit whatever files you need", so there is nothing for it to
--- degrade to -- it fails before a spinner goes up rather than after a request
--- that could never have worked.
---
--- Nothing else is here, because every other op adapts instead. `explain`
--- writes nothing, so the worst a chat-only provider can do is answer from the
--- selection instead of from the repository -- exactly what you want when the
--- question is about the selected text itself ("why is this Präteritum?")
--- rather than about how it fits the codebase. `replace` returns the
--- replacement text directly instead of writing it to a temp file. In both
--- cases prompt.lua swaps the wording to match, so a model is never told to
--- use tools it has no way of using.
--- @type table<string, boolean>
local AGENTIC_OPS = { ask = true }

--- @param opts gerty.Config|nil
function M.setup(opts)
  cfg = config.resolve(opts)
  skill_map = skills.discover(cfg.skills)
end

--- Re-scan the configured skill directories, e.g. after adding a new SKILL.md.
function M.refresh_skills()
  assert(cfg, "gerty: call setup() first")
  skill_map = skills.discover(cfg.skills)
end

--- @param op string|nil
--- @return string|nil op
local function valid_op(op)
  if op == nil then
    return nil
  end
  assert(
    config.ops[op],
    "gerty: unknown operation '"
      .. tostring(op)
      .. "' -- known operations: "
      .. table.concat(config.op_names(), ", ")
  )
  return op
end

--- Every op goes through here, so a per-call `$alias`, a per-op default and
--- the global default resolve identically -- in that order of precedence.
--- @param op string|nil
--- @param alias string|nil per-call override, wins over everything
--- @return gerty.ResolvedProvider
local function pick_provider(op, alias)
  local key = alias or (op and cfg.op_defaults[op]) or cfg.default
  local provider = cfg.providers[key]
  assert(
    provider,
    "gerty: unknown provider '"
      .. tostring(key)
      .. "' -- configured providers: "
      .. table.concat(cfg.provider_names, ", ")
  )
  -- fail before a spinner goes up, not after a request that can't work
  assert(
    not (op and AGENTIC_OPS[op]) or transport.is_agentic(provider),
    "gerty: provider '"
      .. provider.alias
      .. "' is chat-only and cannot run '"
      .. tostring(op)
      .. "' -- that operation needs a provider with its own tools ("
      .. "a CLI one, e.g. pi or claude)"
  )
  return provider
end

--- The whole reason this exists: "claude-sonnet-5" doesn't tell you whether
--- that's the `claude` CLI on your subscription or `pi` routed through a
--- pay-per-token gateway with a model of the same name -- both would render
--- identically without the provider (and, where you've set it, the billing
--- path) spelled out.
--- @param alias string
--- @param model string|nil defaults to the provider's current model
--- @return string e.g. "claude (claude-sonnet-5) [Claude Max]"
local function provider_label(alias, model)
  local provider = cfg.providers[alias]
  local label =
    string.format("%s (%s)", alias, model or provider.model or "provider default")
  local billing = config.billing_for(provider, model)
  if billing then
    label = label .. " [" .. billing .. "]"
  end
  return label
end

--- Sets the global default provider -- the one used by any op without its own
--- op_defaults entry. Session-only: nothing is written back to your config.
--- @param alias string
function M.set_provider(alias)
  assert(cfg, "gerty: call setup() first")
  local provider = pick_provider(nil, alias)
  cfg.default = provider.alias
  vim.notify(
    "gerty: default provider set to " .. provider_label(provider.alias),
    vim.log.levels.INFO
  )
end

--- @param op string|nil
--- @return string the provider alias that op (or the global default) resolves to
function M.get_provider(op)
  assert(cfg, "gerty: call setup() first")
  return pick_provider(valid_op(op), nil).alias
end

--- The everyday model switcher. One flat list of every model on every
--- configured provider -- no "which role do you want to retarget?" step,
--- because a model is not a role: it is a thing you point at whatever you are
--- doing right now.
---
--- Picking one sets **both** the default provider and that provider's current
--- model, which is the whole switch in a single choice. A model belongs to
--- exactly one provider by construction (it is declared inside it), so there
--- is nothing left to keep in sync -- no candidate carrying its own provider,
--- no billing tag that can go stale after a pick.
---
--- Ops with their own `op_defaults` entry are deliberately unaffected: setting
--- the default to a Claude model should not drag translation off the local
--- model it was routed to on purpose.
---
--- @param opts { provider: string|nil }|nil limits the list to one provider
function M.select_model(opts)
  assert(cfg, "gerty: call setup() first")
  opts = opts or {}

  local aliases = opts.provider and { opts.provider } or cfg.provider_names
  local choices = {}
  for _, alias in ipairs(aliases) do
    local provider = cfg.providers[alias]
    assert(
      provider,
      "gerty: unknown provider \'" .. tostring(alias) .. "\'"
    )
    for _, model in ipairs(provider.models) do
      table.insert(choices, { alias = alias, model = model })
    end
  end

  if #choices == 0 then
    vim.notify(
      "gerty: no models configured -- add `models` to a provider in setup()",
      vim.log.levels.WARN
    )
    return
  end

  vim.ui.select(choices, {
    prompt = "gerty: model (currently " .. provider_label(cfg.default) .. ")",
    format_item = function(choice)
      local label = string.format("%s: %s", choice.alias, choice.model.name)
      if choice.model.billing then
        label = label .. " [" .. choice.model.billing .. "]"
      end
      return label
    end,
  }, function(choice)
    if not choice then
      return
    end
    cfg.providers[choice.alias].model = choice.model.id
    cfg.default = choice.alias
    vim.notify("gerty: " .. provider_label(choice.alias), vim.log.levels.INFO)
  end)
end

--- The language pair (and the rest of `config.language`) for this session.
--- Same mechanism as set_provider: in-memory, no config edit, no restart.
--- @param opts { source: string|nil, target: string|nil, context_lines: number|nil, learner_level: string|nil }
function M.set_language(opts)
  assert(cfg, "gerty: call setup() first")
  assert(type(opts) == "table", "gerty: set_language() takes a table")
  for key, value in pairs(opts) do
    assert(
      cfg.language[key] ~= nil,
      "gerty: config.language has no field '" .. tostring(key) .. "'"
    )
    cfg.language[key] = value
  end
  vim.notify(
    "gerty: language set to " .. cfg.language.source .. " -> " .. cfg.language.target,
    vim.log.levels.INFO
  )
end

--- @return gerty.LanguageConfig a copy -- mutate it and nothing happens
function M.get_language()
  assert(cfg, "gerty: call setup() first")
  return vim.deepcopy(cfg.language)
end

--- Prompts with vim.ui.select over config.language_presets.
function M.select_language()
  assert(cfg, "gerty: call setup() first")
  if #cfg.language_presets == 0 then
    vim.notify(
      "gerty: no language_presets configured -- use set_language() instead",
      vim.log.levels.WARN
    )
    return
  end
  vim.ui.select(cfg.language_presets, {
    prompt = "gerty language",
    format_item = function(preset)
      return string.format(
        "%s -> %s",
        prompt.language_name(preset.source),
        prompt.language_name(preset.target)
      )
    end,
  }, function(choice)
    if choice then
      M.set_language({ source = choice.source, target = choice.target })
    end
  end)
end

function M.cancel_all()
  -- jobs.cancel_all resolves each job as "cancelled", and those callbacks
  -- already tear their own UI down; the loop below is the safety net for
  -- anything that somehow outlived its job
  jobs.cancel_all()
  for _, op in pairs(active) do
    op.spinner:stop()
    if op.bottom_spinner then
      op.bottom_spinner:stop()
    end
    if op.dim_id then
      Spinner.undim(op.dim_buf, op.dim_id)
    end
  end
  active = {}
end

--- Leaving visual mode sets the '< '> marks; feeding <Esc> guarantees we're
--- out of visual mode before reading them, whether we're called from a
--- visual-mode keymap or from the command line.
--- @return number, number 1-indexed inclusive start/end lines
local function visual_line_range()
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
    "x",
    false
  )
  local s = vim.fn.getpos("'<")[2]
  local e = vim.fn.getpos("'>")[2]
  if s > e then
    s, e = e, s
  end
  return s, e
end

--- @param buf number
--- @param s number 1-indexed
--- @param e number 1-indexed
--- @param n number
--- @return string
local function surrounding_context(buf, s, e, n)
  local total = vim.api.nvim_buf_line_count(buf)
  local from = math.max(s - 1 - n, 0)
  local to = math.min(e + n, total)
  return table.concat(vim.api.nvim_buf_get_lines(buf, from, to, false), "\n")
end

--- Marks every line in [start_row, end_row] as "translated" with a persistent
--- sign, replacing any marks already there so a repeat lookup (or a cache
--- hit) doesn't stack duplicates.
--- @param buf number
--- @param start_row number 1-indexed inclusive
--- @param end_row number 1-indexed inclusive
local function mark_translated(buf, start_row, end_row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, translated_ns, start_row - 1, end_row)
  for row = start_row - 1, end_row - 1 do
    vim.api.nvim_buf_set_extmark(buf, translated_ns, row, 0, {
      sign_text = "▎",
      sign_hl_group = "DiagnosticHint",
    })
  end
end

--- @param s string
--- @param n number
--- @return string
local function truncate(s, n)
  s = s:gsub("%s+", " ")
  if #s > n then
    return s:sub(1, n - 1) .. "…"
  end
  return s
end

--- The provider alias only earns space in the status line when there's more
--- than one to tell apart.
--- @param verb string
--- @param provider gerty.ResolvedProvider
--- @param skill_names string[]
--- @return string
local function status_label(verb, provider, skill_names)
  local label = "gerty: " .. verb
  if #cfg.provider_names > 1 then
    label = label .. " @" .. provider.alias
  end
  if #skill_names > 0 then
    label = label .. " [" .. table.concat(skill_names, ",") .. "]"
  end
  return label
end

--- A leading `$alias` picks the provider for this one call, above the per-op
--- default, above the global one, and above whichever key was used to submit
--- the prompt. Anything else -- `$notaprovider`, a `$` in the middle of a
--- sentence -- is left in the instruction untouched, because silently eating
--- part of someone's prompt is worse than ignoring a typo.
--- @param instruction string
--- @return string|nil provider alias
--- @return string the instruction with the token removed, if one matched
local function split_alias(instruction)
  local name, rest = instruction:match("^%s*%$(%S+)%s*(.*)$")
  if name and cfg.providers[name] then
    return name, rest
  end
  return nil, instruction
end

--- One entry per line rather than one giant comma-joined paragraph -- past
--- two or three providers the joined version just ran off the window with
--- nothing to visually anchor on. hint.lua colors the leading `$`/`#` token
--- and the trailing `(...)`/`[...]` metadata on each of these automatically.
--- @return string[]
local function hint_lines()
  local lines = {}

  if #cfg.provider_names > 1 then
    table.insert(lines, "Available providers:")
    for _, alias in ipairs(cfg.provider_names) do
      table.insert(lines, "  $" .. provider_label(alias))
    end
  end

  local names = vim.tbl_keys(skill_map)
  table.sort(names)
  if #names > 0 then
    table.insert(lines, "Available skills:")
    for _, name in ipairs(names) do
      table.insert(lines, "  #" .. name)
    end
  end

  return lines
end

--- vim.ui.input() with the `$alias`/`#skill` reference card alongside it. The
--- card closes on submit *and* on cancel, because vim.ui.input calls back
--- either way.
--- @param label string
--- @param on_submit fun(instruction: string|nil)
local function input_with_hint(label, on_submit)
  local close = hint.open(hint_lines())
  local ok, err = pcall(vim.ui.input, { prompt = label }, function(instruction)
    close()
    on_submit(instruction)
  end)
  if not ok then
    close()
    error(err)
  end
end

--- Also reached from completion callbacks, by which time the buffer may have
--- been closed -- so an invalid id is a name, not an error.
--- @param buf number
--- @return string
local function buffer_name(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return "[closed buffer]"
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return "[unnamed buffer]"
  end
  return name
end

--- @param buf number
--- @param s number 1-indexed inclusive
--- @param e number 1-indexed inclusive
--- @param instruction string
--- A chat model reaches for a markdown fence even when told not to, and the
--- schema constrains the JSON shape, not what goes inside the string. Stripped
--- only when a fence wraps the WHOLE answer -- a replacement that legitimately
--- contains a fenced block partway through is left exactly as it came.
--- @param text string
--- @return string
local function strip_code_fence(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines < 2 or not lines[1]:match("^%s*```") then
    return text
  end
  local last = #lines
  while last > 1 and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  if last < 2 or not lines[last]:match("^%s*```%s*$") then
    return text
  end
  return table.concat(vim.list_slice(lines, 2, last - 1), "\n")
end

--- Two ways home, chosen by what the provider can actually do.
---
--- An agentic provider writes the replacement to a temp file and touches
--- nothing else -- that indirection is what keeps a model with full file
--- access from wandering off and editing the rest of the repository.
---
--- A chat-only provider has no tools to write with, so it returns the
--- replacement as its answer and the schema in transport.lua is what keeps
--- anything else out of it. Same op, same keybinding, same result in the
--- buffer; the only thing that changes is which mechanism carries the text.
---
--- @param buf number
--- @param s number 1-indexed inclusive
--- @param e number 1-indexed inclusive
--- @param instruction string
--- @param model string|nil overrides the provider's model for this call only
--- @param provider_name string|nil overrides the default provider for this call
local function do_replace(buf, s, e, instruction, model, provider_name)
  local alias, rest = split_alias(instruction)
  instruction = rest
  local provider = pick_provider("replace", alias or provider_name)
  local agentic = transport.is_agentic(provider)
  local selected =
    table.concat(vim.api.nvim_buf_get_lines(buf, s - 1, e, false), "\n")
  local skill_names, skill_contents = skills.resolve(instruction, skill_map)
  local tmp_file = agentic and vim.fn.tempname() or nil

  local start_mark = vim.api.nvim_buf_set_extmark(buf, marks_ns, s - 1, 0, {})
  local end_mark = vim.api.nvim_buf_set_extmark(buf, marks_ns, e - 1, 0, {})

  local request = prompt.replace({
    instruction = instruction,
    filetype = vim.bo[buf].filetype,
    selection = selected,
    context = surrounding_context(buf, s, e, cfg.context_lines),
    tmp_file = tmp_file,
    skills = skill_contents,
    agentic = agentic,
  })

  local label = status_label("replacing", provider, skill_names)
  local dim_id = Spinner.dim_range(buf, s - 1, e - 1)
  local spinner = Spinner.attach(buf, s - 1, label, cfg.spinner_interval, true)
  local bottom_spinner =
    Spinner.attach(buf, e - 1, label, cfg.spinner_interval, false)

  local id
  id = transport.send(provider, request, {
    model = model,
    read_only = false,
    on_stdout = function(line)
      spinner:push(line)
    end,
    on_exit = function(result)
      active[id] = nil
      spinner:stop()
      bottom_spinner:stop()
      Spinner.undim(buf, dim_id)

      -- Read and delete the temp file FIRST, before any early return can skip
      -- it. Everything else here recovers on its own; a leaked scratch file is
      -- the one consequence that outlives the session.
      local lines
      if tmp_file then
        if result.status == "ok" then
          local read_ok, read_lines = pcall(vim.fn.readfile, tmp_file)
          lines = read_ok and read_lines or nil
        end
        pcall(os.remove, tmp_file)
      elseif result.status == "ok" then
        lines = vim.split(strip_code_fence(result.output), "\n", { plain = true })
      end

      if result.status == "cancelled" then
        return
      end
      if result.status == "error" then
        vim.notify("gerty: " .. result.error, vim.log.levels.ERROR)
        return
      end

      -- "keep editing while it runs" includes closing the file you started
      -- from; there is nowhere to put the answer, so say so and stop
      if not vim.api.nvim_buf_is_valid(buf) then
        vim.notify(
          "gerty: buffer was closed while the request was running, discarding replace",
          vim.log.levels.WARN
        )
        return
      end

      local start_pos =
        vim.api.nvim_buf_get_extmark_by_id(buf, marks_ns, start_mark, {})
      local end_pos =
        vim.api.nvim_buf_get_extmark_by_id(buf, marks_ns, end_mark, {})
      pcall(vim.api.nvim_buf_del_extmark, buf, marks_ns, start_mark)
      pcall(vim.api.nvim_buf_del_extmark, buf, marks_ns, end_mark)

      if #start_pos == 0 or #end_pos == 0 then
        vim.notify(
          "gerty: selection was destroyed while the request was running, aborting replace",
          vim.log.levels.WARN
        )
        return
      end

      if not lines or #lines == 0 then
        vim.notify("gerty: empty or unreadable response", vim.log.levels.WARN)
        return
      end

      vim.api.nvim_buf_set_lines(
        buf,
        start_pos[1],
        end_pos[1] + 1,
        false,
        lines
      )
    end,
  })

  active[id] = {
    spinner = spinner,
    bottom_spinner = bottom_spinner,
    dim_buf = buf,
    dim_id = dim_id,
  }
end

--- Read-only: the model may explore the whole repository but must not write
--- to it, and the answer lands in a scratch float instead of the buffer.
--- @param buf number
--- @param s number 1-indexed inclusive
--- @param e number 1-indexed inclusive
--- @param instruction string
--- @param model string|nil overrides the provider's model for this call only
--- @param provider_name string|nil overrides the default provider for this call
local function do_explain(buf, s, e, instruction, model, provider_name)
  local alias, rest = split_alias(instruction)
  instruction = rest
  local provider = pick_provider("explain", alias or provider_name)
  local selected =
    table.concat(vim.api.nvim_buf_get_lines(buf, s - 1, e, false), "\n")
  local skill_names, skill_contents = skills.resolve(instruction, skill_map)

  local request = prompt.explain({
    instruction = instruction,
    cwd = vim.uv.cwd(),
    file = buffer_name(buf),
    filetype = vim.bo[buf].filetype,
    start_line = s,
    end_line = e,
    selection = selected,
    skills = skill_contents,
    agentic = transport.is_agentic(provider),
  })

  local label = status_label("explaining", provider, skill_names)
  local spinner = Spinner.attach(buf, s - 1, label, cfg.spinner_interval, true)

  local id
  id = transport.send(provider, request, {
    model = model,
    read_only = true,
    on_stdout = function(l)
      spinner:push(l)
    end,
    on_exit = function(result)
      active[id] = nil
      spinner:stop()
      if result.status == "cancelled" then
        return
      end
      if result.status == "error" then
        vim.notify("gerty: " .. result.error, vim.log.levels.ERROR)
        return
      end
      local title = string.format(
        "gerty: %s:%d-%d",
        vim.fn.fnamemodify(buffer_name(buf), ":t"),
        s,
        e
      )
      if not float.show(title, result.output) then
        vim.notify("gerty: empty response", vim.log.levels.WARN)
      end
    end,
  })

  active[id] = { spinner = spinner }
end

--- @param instruction string
--- @param model string|nil overrides the provider's model for this call only
--- @param provider_name string|nil overrides the default provider for this call
local function do_ask(instruction, model, provider_name)
  local alias, rest = split_alias(instruction)
  instruction = rest
  local provider = pick_provider("ask", alias or provider_name)
  local buf = vim.api.nvim_get_current_buf()
  local skill_names, skill_contents = skills.resolve(instruction, skill_map)
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local request = prompt.ask({
    instruction = instruction,
    cwd = vim.uv.cwd(),
    file = buffer_name(buf),
    skills = skill_contents,
  })

  local spinner = Spinner.attach(
    buf,
    line,
    status_label("working", provider, skill_names),
    cfg.spinner_interval
  )

  local id
  id = transport.send(provider, request, {
    model = model,
    read_only = false,
    on_stdout = function(l)
      spinner:push(l)
    end,
    on_exit = function(result)
      active[id] = nil
      spinner:stop()
      if result.status == "cancelled" then
        return
      end
      if result.status == "error" then
        vim.notify("gerty: " .. result.error, vim.log.levels.ERROR)
        return
      end
      -- the model may have edited files on disk out from under open buffers
      vim.cmd("checktime")
      vim.notify("gerty: done", vim.log.levels.INFO)
    end,
  })

  active[id] = { spinner = spinner }
end

--- @param opts table
--- @return gerty.LanguageConfig the session language with per-call overrides
local function language_for(opts)
  return {
    source = opts.source or cfg.language.source,
    target = opts.target or cfg.language.target,
    context_lines = opts.context_lines or cfg.language.context_lines,
    learner_level = opts.learner_level or cfg.language.learner_level,
  }
end

--- Shared tail of `translate` and `gloss`: dim the selection and spin above
--- and below it -- the same "about to change" treatment `replace` uses,
--- because a translation replacing your view of the text while you wait
--- benefits from the same visual cue as an edit would. Resolves in a float,
--- never writes a character back into the buffer, caches a successful answer
--- under `cache_key` so asking again is instant, records it in history, and
--- leaves a persistent sign on the lines it covered.
--- @param op "translate"|"gloss"
--- @param verb string
--- @param sel gerty.Selection
--- @param request gerty.Prompt
--- @param provider gerty.ResolvedProvider
--- @param skill_names string[]
--- @param model string|nil
--- @param title string
--- @param cache_key string
--- @param history_label string
local function run_language_op(
  op,
  verb,
  sel,
  request,
  provider,
  skill_names,
  model,
  title,
  cache_key,
  history_label
)
  local label = status_label(verb, provider, skill_names)
  local dim_id = Spinner.dim_range(sel.buf, sel.start_row - 1, sel.end_row - 1)
  local spinner =
    Spinner.attach(sel.buf, sel.start_row - 1, label, cfg.spinner_interval, true)
  local bottom_spinner =
    Spinner.attach(sel.buf, sel.end_row - 1, label, cfg.spinner_interval, false)

  local id
  id = transport.send(provider, request, {
    model = model,
    -- a CLI provider standing in for a chat model still must not touch the
    -- working tree: these ops read prose, they don't edit anything
    read_only = true,
    on_stdout = function(l)
      spinner:push(l)
    end,
    on_exit = function(result)
      active[id] = nil
      spinner:stop()
      bottom_spinner:stop()
      Spinner.undim(sel.buf, dim_id)
      if result.status == "cancelled" then
        return
      end
      if result.status == "error" then
        vim.notify("gerty: " .. result.error, vim.log.levels.ERROR)
        return
      end
      if not float.show(title, result.output) then
        vim.notify("gerty: empty response", vim.log.levels.WARN)
        return
      end
      cache.set(cache_key, result.output)
      mark_translated(sel.buf, sel.start_row, sel.end_row)
      history.record({
        op = op,
        label = history_label,
        cache_key = cache_key,
        buf = sel.buf,
        start_row = sel.start_row,
        end_row = sel.end_row,
      })
    end,
  })

  active[id] = {
    spinner = spinner,
    bottom_spinner = bottom_spinner,
    dim_buf = sel.buf,
    dim_id = dim_id,
  }
end

--- @param sel gerty.Selection
--- @param opts table
local function do_translate(sel, opts)
  local provider = pick_provider("translate", opts.provider)
  local lang = language_for(opts)
  local before, after = selection.context(sel, lang.context_lines)
  local model = opts.model or provider.model
  local title = string.format("gerty: translate %d-%d", sel.start_row, sel.end_row)

  local cache_key = cache.key({
    "translate",
    sel.text,
    before,
    after,
    lang.source,
    lang.target,
    provider.alias,
    model,
  })
  local history_label = string.format(
    "%s (%s → %s)",
    truncate(sel.text, 60),
    prompt.language_name(lang.source),
    prompt.language_name(lang.target)
  )

  if not opts.refresh then
    local cached = cache.get(cache_key)
    if cached then
      mark_translated(sel.buf, sel.start_row, sel.end_row)
      history.record({
        op = "translate",
        label = history_label,
        cache_key = cache_key,
        buf = sel.buf,
        start_row = sel.start_row,
        end_row = sel.end_row,
      })
      float.show(title .. " (cached)", cached)
      return
    end
  end

  local request = prompt.translate({
    source = lang.source,
    target = lang.target,
    before = before,
    after = after,
    selection = sel.text,
  })

  run_language_op(
    "translate",
    "translating",
    sel,
    request,
    provider,
    {},
    model,
    title,
    cache_key,
    history_label
  )
end

--- @param sel gerty.Selection
--- @param instruction string blank means "the default grammar breakdown"
--- @param opts table
local function do_gloss(sel, instruction, opts)
  local alias, rest = split_alias(instruction)
  instruction = rest
  local provider = pick_provider("gloss", alias or opts.provider)
  local lang = language_for(opts)
  local before, after = selection.context(sel, lang.context_lines)
  local skill_names, skill_contents = skills.resolve(instruction, skill_map)
  local model = opts.model or provider.model
  local title = string.format("gerty: gloss %d-%d", sel.start_row, sel.end_row)

  local cache_key = cache.key({
    "gloss",
    sel.text,
    before,
    after,
    lang.source,
    lang.target,
    lang.learner_level,
    instruction,
    provider.alias,
    model,
  })
  local trimmed_instruction = vim.trim(instruction)
  local history_label = string.format(
    "[gloss%s] %s (%s → %s)",
    trimmed_instruction == "" and "" or ": " .. truncate(trimmed_instruction, 24),
    truncate(sel.text, 50),
    prompt.language_name(lang.source),
    prompt.language_name(lang.target)
  )

  if not opts.refresh then
    local cached = cache.get(cache_key)
    if cached then
      mark_translated(sel.buf, sel.start_row, sel.end_row)
      history.record({
        op = "gloss",
        label = history_label,
        cache_key = cache_key,
        buf = sel.buf,
        start_row = sel.start_row,
        end_row = sel.end_row,
      })
      float.show(title .. " (cached)", cached)
      return
    end
  end

  local request = prompt.gloss({
    source = lang.source,
    target = lang.target,
    learner_level = lang.learner_level,
    instruction = instruction,
    before = before,
    after = after,
    selection = sel.text,
    skills = skill_contents,
  })

  run_language_op(
    "gloss",
    "glossing",
    sel,
    request,
    provider,
    skill_names,
    model,
    title,
    cache_key,
    history_label
  )
end

--- Replace the current visual selection with the result of an instruction.
--- Only ever writes to the selected range; never touches other files.
--- @param opts { instruction: string|nil, model: string|nil, provider: string|nil }|nil
function M.replace(opts)
  assert(cfg, "gerty: call require('gerty').setup() first")
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local s, e = visual_line_range()

  if opts.instruction then
    do_replace(buf, s, e, opts.instruction, opts.model, opts.provider)
    return
  end

  input_with_hint("Replace: ", function(instruction)
    if instruction and vim.trim(instruction) ~= "" then
      do_replace(buf, s, e, instruction, opts.model, opts.provider)
    end
  end)
end

--- Ask a question about the current visual selection. The model may read the
--- whole repository to answer, but cannot modify anything; the answer opens
--- in a scratch float. Defaults to "explain this code" if no instruction is
--- given at the prompt.
--- @param opts { instruction: string|nil, model: string|nil, provider: string|nil }|nil
function M.explain(opts)
  assert(cfg, "gerty: call require('gerty').setup() first")
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local s, e = visual_line_range()

  if opts.instruction then
    do_explain(buf, s, e, opts.instruction, opts.model, opts.provider)
    return
  end

  input_with_hint("Explain: ", function(instruction)
    if instruction == nil then
      return
    end
    if vim.trim(instruction) == "" then
      instruction = "Explain what this code does, why it exists, and how it "
        .. "is used elsewhere in the repository."
    end
    do_explain(buf, s, e, instruction, opts.model, opts.provider)
  end)
end

--- Send an instruction to an agentic run that may edit any file it needs to.
--- @param opts { instruction: string|nil, model: string|nil, provider: string|nil }|nil
function M.ask(opts)
  assert(cfg, "gerty: call require('gerty').setup() first")
  opts = opts or {}

  if opts.instruction then
    do_ask(opts.instruction, opts.model, opts.provider)
    return
  end

  input_with_hint("Ask: ", function(instruction)
    if instruction and vim.trim(instruction) ~= "" then
      do_ask(instruction, opts.model, opts.provider)
    end
  end)
end

--- Translate the current visual selection. The surrounding lines go along as
--- context the model is told not to translate, only to disambiguate with.
--- The answer opens in a float; the buffer is never touched. A repeat call
--- with the same selection, context, language and provider/model returns the
--- cached answer instantly -- pass `refresh = true` to force a fresh request.
--- @param opts { model: string|nil, provider: string|nil, source: string|nil, target: string|nil, context_lines: number|nil, refresh: boolean|nil }|nil
function M.translate(opts)
  assert(cfg, "gerty: call require('gerty').setup() first")
  opts = opts or {}
  local sel = selection.capture_visual()
  selection.exit_visual()
  if not sel or vim.trim(sel.text) == "" then
    vim.notify("gerty: empty selection", vim.log.levels.WARN)
    return
  end
  do_translate(sel, opts)
end

--- Explain the grammar and vocabulary of the current visual selection. An
--- empty prompt gives the default breakdown for the configured learner level;
--- anything typed becomes the instruction instead. Read-only, like translate.
--- Cached the same way translate() is -- pass `refresh = true` to bypass it.
--- @param opts { instruction: string|nil, model: string|nil, provider: string|nil, source: string|nil, target: string|nil, context_lines: number|nil, learner_level: string|nil, refresh: boolean|nil }|nil
function M.gloss(opts)
  assert(cfg, "gerty: call require('gerty').setup() first")
  opts = opts or {}
  -- capture before anything else: once the prompt opens, visual mode is gone
  -- and the selection is unreadable
  local sel = selection.capture_visual()
  selection.exit_visual()
  if not sel or vim.trim(sel.text) == "" then
    vim.notify("gerty: empty selection", vim.log.levels.WARN)
    return
  end

  if opts.instruction then
    do_gloss(sel, opts.instruction, opts)
    return
  end

  input_with_hint("Gloss: ", function(instruction)
    if instruction == nil then
      return
    end
    do_gloss(sel, instruction, opts)
  end)
end

--- Dictionary lookup of the word under the cursor. No model, no provider, no
--- prompt -- just the configured dictionary binary, run through the same job
--- runner as everything else so cancel_all() covers it too. Cached like
--- translate/gloss -- pass `refresh = true` to bypass it.
--- @param opts { source: string|nil, target: string|nil, word: string|nil, refresh: boolean|nil }|nil
function M.word(opts)
  assert(cfg, "gerty: call require('gerty').setup() first")
  opts = opts or {}
  local word = opts.word or vim.fn.expand("<cword>")
  if word == nil or vim.trim(word) == "" then
    vim.notify("gerty: no word under cursor", vim.log.levels.WARN)
    return
  end

  local lang = language_for(opts)
  local source = cfg.dictionary.source or lang.source
  local target = cfg.dictionary.target or lang.target
  local title = string.format("gerty: %s (%s:%s)", word, source, target)

  local cache_key =
    cache.key({ "word", word, source, target, table.concat(cfg.dictionary.command, " ") })
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local history_entry = {
    op = "word",
    label = title,
    cache_key = cache_key,
    buf = buf,
    start_row = line,
    end_row = line,
  }

  if not opts.refresh then
    local cached = cache.get(cache_key)
    if cached then
      history.record(history_entry)
      float.show(title .. " (cached)", cached)
      return
    end
  end

  local cmd = vim.deepcopy(cfg.dictionary.command)
  table.insert(cmd, source .. ":" .. target)
  table.insert(cmd, word)

  local spinner = Spinner.attach(
    buf,
    line - 1,
    "gerty: looking up " .. word,
    cfg.spinner_interval
  )

  local id
  id = jobs.spawn(cmd, {
    on_exit = function(result)
      active[id] = nil
      spinner:stop()
      if result.status == "cancelled" then
        return
      end
      if result.status == "error" then
        vim.notify(
          "gerty: " .. cfg.dictionary.command[1] .. ": " .. result.error,
          vim.log.levels.ERROR
        )
        return
      end
      local text = vim.trim(result.output)
      if text == "" then
        vim.notify("gerty: no dictionary entry for " .. word, vim.log.levels.WARN)
        return
      end
      float.show(title, text)
      cache.set(cache_key, text)
      history.record(history_entry)
    end,
  })

  active[id] = { spinner = spinner }
end

--- Drops every cached translate/gloss/word answer.
function M.clear_cache()
  cache.clear()
  vim.notify("gerty: cache cleared", vim.log.levels.INFO)
end

--- Prompts with vim.ui.select over recent translate/gloss/word lookups,
--- most recent first. Picking one (Enter) jumps back to where it came from
--- if that buffer/line still exists, and shows the cached answer -- no
--- request is sent, even if the entry has since fallen out of cache (in
--- which case you're told to look it up again instead).
function M.history()
  assert(cfg, "gerty: call setup() first")
  local list = history.list()
  if #list == 0 then
    vim.notify("gerty: no history yet", vim.log.levels.WARN)
    return
  end
  vim.ui.select(list, {
    prompt = "gerty history",
    format_item = function(entry)
      return entry.label
    end,
  }, function(entry)
    if not entry then
      return
    end
    local answer = cache.get(entry.cache_key)
    if not answer then
      vim.notify(
        "gerty: that answer is no longer cached -- run it again",
        vim.log.levels.WARN
      )
      return
    end
    if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) and entry.start_row then
      pcall(vim.api.nvim_set_current_buf, entry.buf)
      pcall(vim.api.nvim_win_set_cursor, 0, { entry.start_row, 0 })
    end
    float.show(entry.label .. " (history)", answer)
  end)
end

--- Clears the history list. The cache itself is untouched -- use
--- clear_cache() for that.
function M.clear_history()
  history.clear()
  vim.notify("gerty: history cleared", vim.log.levels.INFO)
end

--- Clears the persistent "translated" line signs. With no `buf`, clears
--- every buffer that has any.
--- @param buf number|nil
function M.clear_marks(buf)
  if buf then
    vim.api.nvim_buf_clear_namespace(buf, translated_ns, 0, -1)
    return
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_clear_namespace(b, translated_ns, 0, -1)
    end
  end
end

--- The provider *types* -- exposed for a custom `type` table in setup().
M.provider_types = require("gerty.providers")

return M
