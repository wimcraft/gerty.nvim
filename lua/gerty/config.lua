local provider_types = require("gerty.providers")

--- One model you can point a provider at. Declared inside the provider that
--- serves it, so -- unlike the old flat catalog -- a model can never be
--- offered without the provider that knows how to run it, and picking one can
--- never leave a stale `billing` tag behind.
---
--- `billing` is display-only: gerty never reads it to decide anything. It
--- exists because the same CLI can be pointed at a subscription-covered model
--- or a pay-per-token gateway model depending entirely on which model string
--- it's handed, so `pi` + "claude-sonnet-5" and `claude` + "claude-sonnet-5"
--- would otherwise render identically in every picker despite one being
--- flat-rate and the other metered. Set once on the provider and inherited by
--- its models; override per model for the mixed case (a `pi` that reaches both
--- a Codex subscription and a pay-per-token gateway).
---
--- @class gerty.ModelSpec
--- @field id string model id passed to the provider, e.g. "kilo/deepseek/deepseek-v4-pro"
--- @field name string|nil label shown in pickers; defaults to id
--- @field billing string|nil overrides the provider's billing tag for this model

--- What you actually write in `config.providers`. The key is the alias you
--- type as `$alias` and see in every picker; `type` names the mechanism, and
--- defaults to the alias itself when the alias happens to name a known one --
--- so `pi = {}` and `claude = {}` need nothing else, while
--- `["local"] = { type = "lmstudio" }` spells it out.
---
--- Every field except `type` is optional. A provider with no `models` runs
--- whatever its CLI is already configured to run.
---
--- @class gerty.ProviderSpec
--- @field type string|gerty.ProviderType|nil "pi"|"claude"|"lmstudio"|"ollama"|"openai_compat", or a type table; defaults to the alias
--- @field endpoint string|nil overrides the type's endpoint (openai_compat family)
--- @field temperature number|nil overrides the type's temperature
--- @field json_schema boolean|nil set false to skip constrained decoding; see transport.lua
--- @field chat_template_kwargs table|nil extra kwargs for the server's chat template, e.g. `{ enable_thinking = true }`
--- @field models (string|gerty.ModelSpec)[]|nil offered by select_model()
--- @field model string|nil the current model; defaults to models[1], then the type's default
--- @field billing string|nil display-only tag inherited by this provider's models
--- @field extra_args string[]|nil extra CLI args appended before the prompt
--- @field build_command fun(provider: gerty.ResolvedProvider, opts: gerty.CommandOpts|nil): string[]|nil escape hatch; overrides the type's

--- A spec merged onto its type. This is the object every other module works
--- with: it carries the model and the args, so nothing else has to pair a
--- provider with a model to send a request.
--- @class gerty.ResolvedProvider
--- @field alias string the `$alias` name
--- @field name string the mechanism's name
--- @field transport "cli"|"openai_compat"
--- @field capabilities gerty.ProviderCapabilities
--- @field model string|nil current model; mutated by select_model() for the session
--- @field models gerty.ModelSpec[]
--- @field billing string|nil
--- @field extra_args string[]
--- @field endpoint string|nil
--- @field temperature number|nil
--- @field json_schema boolean
--- @field chat_template_kwargs table|nil
--- @field build_command fun(provider: gerty.ResolvedProvider, opts: gerty.CommandOpts|nil): string[]

--- Shared by `translate`, `gloss` and `word`. Every field can be overridden
--- per call, and the pair can be swapped mid-session with set_language() /
--- select_language() without touching this config.
---
--- @class gerty.LanguageConfig
--- @field source string ISO code of the language being read, e.g. "de"
--- @field target string ISO code to answer in, e.g. "en"
--- @field context_lines number lines around the selection sent for disambiguation
--- @field learner_level string audience for `gloss`, e.g. "intermediate"

--- @class gerty.LanguagePreset
--- @field source string
--- @field target string

--- `word` never involves a model -- it shells out to a dictionary binary.
--- @class gerty.DictionaryConfig
--- @field command string[] argv prefix; the language pair and word are appended
--- @field source string|nil defaults to language.source
--- @field target string|nil defaults to language.target

--- @class gerty.Config
--- @field providers table<string, gerty.ResolvedProvider> alias -> provider
--- @field provider_names string[] aliases, sorted -- stable order for pickers
--- @field default string alias used when a call names none
--- @field op_defaults table<string, string> per-operation default alias
--- @field prompt_keys table<string, string|number> prompt-hotkey lhs -> provider alias, or a 1-based index into `provider_names`; inserts a leading `$alias` token at the built-in prompt
--- @field prompt_highlight boolean colour `$provider`/`/skill` tokens live at the built-in prompt (green when they resolve, warn colour when they do not)
--- @field prompt_completion boolean `<Tab>`-complete `/skill` and `$provider` tokens at the built-in prompt
--- @field replace_explain boolean let a referenced skill explain a `replace` edit in a float
--- @field skills string[] directories to scan for <name>/SKILL.md files
--- @field context_lines number lines of surrounding context sent for `replace`
--- @field spinner_interval number ms between spinner frame updates
--- @field language gerty.LanguageConfig
--- @field language_presets gerty.LanguagePreset[] choices offered by select_language()
--- @field dictionary gerty.DictionaryConfig

--- Every operation that can be given its own default provider. Keys of
--- `op_defaults` are validated against this, so a typo fails at setup() rather
--- than silently doing nothing at the first call.
--- @type table<string, boolean>
local OPS = {
  replace = true,
  explain = true,
  ask = true,
  translate = true,
  gloss = true,
}

--- @type gerty.Config
local defaults = {
  providers = {},
  default = nil,
  op_defaults = {},
  -- Off by default, and deliberately so: a keymap here that the terminal
  -- can't deliver (`<C-1>` needs the kitty keyboard protocol; typed `$N`
  -- never does) would just sit there doing nothing, and this project has
  -- turned down a silently-degrading prompt keymap once already. Opt in with
  -- e.g. `prompt_keys = { ["<C-1>"] = 1, ["<C-2>"] = 2 }` -- each value is a
  -- 1-based index into the sorted alias list, or a provider alias.
  prompt_keys = {},
  -- both on: they only touch the built-in prompt, degrade to nothing on a
  -- custom `vim.ui.input`, and are the answer to "which /skills exist and did
  -- mine apply". Set either false to opt out.
  prompt_highlight = true,
  prompt_completion = true,
  -- On, but worth knowing what it costs: with a skill referenced the chat
  -- grammar makes the explanation field *required*, so a skilled `replace`
  -- produces a note every time, not only when the skill asked for one. If
  -- your skills are pure rewrite instructions, turn this off.
  replace_explain = true,
  skills = {},
  context_lines = 40,
  spinner_interval = 120,
  language = {
    source = "de",
    target = "en",
    context_lines = 5,
    learner_level = "intermediate",
  },
  language_presets = {},
  dictionary = { command = { "trans", "-b" } },
}

local M = {}

M.ops = OPS

--- @return string[] operation names, sorted
function M.op_names()
  local names = vim.tbl_keys(OPS)
  table.sort(names)
  return names
end

--- @return string[] known provider type names, sorted
local function type_names()
  local names = vim.tbl_keys(provider_types)
  table.sort(names)
  return names
end

--- @param spec_type string|gerty.ProviderType
--- @param alias string
--- @return gerty.ProviderType
local function resolve_type(spec_type, alias)
  if type(spec_type) == "string" then
    local found = provider_types[spec_type]
    assert(
      found,
      "gerty: provider '"
        .. alias
        .. "' has unknown type '"
        .. spec_type
        .. "' -- known types: "
        .. table.concat(type_names(), ", ")
    )
    return found
  end
  assert(
    type(spec_type) == "table" and spec_type.build_command,
    "gerty: provider '"
      .. alias
      .. "' needs a `type` naming one of: "
      .. table.concat(type_names(), ", ")
      .. " -- or a type table with build_command"
  )
  return spec_type
end

--- Strings are the common case ("claude-opus-5"); the table form is for when
--- a model wants a friendlier label or its own billing tag.
--- @param list (string|gerty.ModelSpec)[]|nil
--- @param alias string
--- @param billing string|nil the provider's tag, inherited unless overridden
--- @return gerty.ModelSpec[]
local function normalise_models(list, alias, billing)
  local out = {}
  for i, entry in ipairs(list or {}) do
    if type(entry) == "string" then
      entry = { id = entry }
    end
    assert(
      type(entry) == "table" and type(entry.id) == "string" and entry.id ~= "",
      "gerty: provider '"
        .. alias
        .. "' models["
        .. i
        .. "] must be a model id string or a table with an `id`"
    )
    table.insert(out, {
      id = entry.id,
      name = entry.name or entry.id,
      billing = entry.billing or billing,
    })
  end
  return out
end

--- @param alias string
--- @param spec gerty.ProviderSpec
--- @return gerty.ResolvedProvider
local function resolve_provider(alias, spec)
  assert(
    type(spec) == "table",
    "gerty: config.providers['" .. alias .. "'] must be a table"
  )
  local t = resolve_type(spec.type or alias, alias)
  local models = normalise_models(spec.models, alias, spec.billing)
  local model = spec.model or (models[1] and models[1].id) or t.default_model

  -- an explicit `model` that isn't in `models` still belongs in the picker --
  -- otherwise select_model() can't get you back to where you started
  if model and not vim.iter(models):any(function(m)
    return m.id == model
  end) then
    table.insert(models, 1, { id = model, name = model, billing = spec.billing })
  end

  local provider = {
    alias = alias,
    name = t.name or alias,
    transport = t.transport or "cli",
    capabilities = t.capabilities or { agentic = true },
    model = model,
    models = models,
    billing = spec.billing,
    extra_args = vim.deepcopy(spec.extra_args or {}),
    endpoint = spec.endpoint or t.endpoint,
    temperature = spec.temperature ~= nil and spec.temperature or t.temperature,
    -- constrained decoding is on by default for chat endpoints: it is what
    -- keeps a reasoning-tuned local model from answering with its own plan,
    -- and it is a latency win as much as a correctness one. See transport.lua.
    json_schema = spec.json_schema ~= false,
    chat_template_kwargs = spec.chat_template_kwargs,
    build_command = spec.build_command or t.build_command,
  }

  if provider.transport == "openai_compat" then
    assert(
      type(provider.endpoint) == "string" and provider.endpoint ~= "",
      "gerty: provider '"
        .. alias
        .. "' needs an `endpoint`, e.g. "
        .. "http://localhost:1234/v1/chat/completions"
    )
  end

  return provider
end

--- The billing tag to show for a provider's current model: the model's own,
--- falling back to the provider's. A `pi` that reaches both a Codex
--- subscription and a pay-per-token gateway needs the per-model answer.
--- @param provider gerty.ResolvedProvider
--- @param model string|nil defaults to the provider's current model
--- @return string|nil
function M.billing_for(provider, model)
  model = model or provider.model
  for _, entry in ipairs(provider.models) do
    if entry.id == model then
      return entry.billing or provider.billing
    end
  end
  return provider.billing
end

--- vim.tbl_deep_extend merges lists element by element, which is fine for
--- defaults that are empty but wrong for a default that has entries: asking
--- for `{ "trans" }` would come back as `{ "trans", "-b" }`. It is wrong for
--- `providers` for the same reason one level down -- a provider's `models`
--- list would be merged with whatever it was extending. These are replaced
--- wholesale instead.
--- @param cfg gerty.Config
--- @param opts gerty.Config|nil
local function restore_list_overrides(cfg, opts)
  if not opts then
    return
  end
  if opts.dictionary and opts.dictionary.command then
    cfg.dictionary.command = vim.deepcopy(opts.dictionary.command)
  end
  if opts.language_presets then
    cfg.language_presets = vim.deepcopy(opts.language_presets)
  end
  if opts.providers then
    cfg.providers = vim.deepcopy(opts.providers)
  end
  -- what the user passes IS the binding set, not a patch on top of one --
  -- same treatment as `providers`, and it keeps behaviour predictable if a
  -- non-empty default is ever reintroduced.
  if opts.prompt_keys then
    cfg.prompt_keys = vim.deepcopy(opts.prompt_keys)
  end
end

--- @param opts gerty.Config|nil
--- @return gerty.Config
function M.resolve(opts)
  local cfg = vim.tbl_deep_extend("force", {}, defaults, opts or {})
  restore_list_overrides(cfg, opts)

  -- zero config still has to work: one `pi` provider on its own defaults
  if vim.tbl_isempty(cfg.providers) then
    cfg.providers = { pi = {} }
  end

  local resolved = {}
  for alias, spec in pairs(cfg.providers) do
    resolved[alias] = resolve_provider(alias, spec)
  end
  cfg.providers = resolved
  cfg.provider_names = vim.tbl_keys(resolved)
  table.sort(cfg.provider_names)

  if cfg.default then
    assert(
      resolved[cfg.default],
      "gerty: config.default '"
        .. tostring(cfg.default)
        .. "' is not one of: "
        .. table.concat(cfg.provider_names, ", ")
    )
  else
    cfg.default = cfg.provider_names[1]
  end

  -- op_defaults gets the same treatment as cfg.default: an unknown name is a
  -- typo, and finding out at setup() beats finding out three ops later
  for op, alias in pairs(cfg.op_defaults) do
    assert(
      OPS[op],
      "gerty: config.op_defaults has no operation '"
        .. tostring(op)
        .. "' -- known operations: "
        .. table.concat(M.op_names(), ", ")
    )
    assert(
      resolved[alias],
      "gerty: config.op_defaults."
        .. op
        .. " = '"
        .. tostring(alias)
        .. "' is not one of: "
        .. table.concat(cfg.provider_names, ", ")
    )
  end

  -- prompt_keys: each value is a provider alias or a 1-based index into the
  -- sorted provider list. A bad one here would otherwise be a keypress that
  -- silently does nothing, with no hint as to why.
  assert(
    type(cfg.prompt_keys) == "table",
    "gerty: config.prompt_keys must be a table of `lhs` -> provider alias or index"
  )
  for lhs, target in pairs(cfg.prompt_keys) do
    assert(
      type(lhs) == "string",
      "gerty: config.prompt_keys keys are keymap left-hand sides, e.g. '<C-1>'"
    )
    -- The range check matters as much as the type check: an index past the
    -- end of the provider list would install a key that does nothing at all,
    -- which is precisely the silent failure this block exists to prevent.
    local ok_target = (
      type(target) == "number"
      and target == math.floor(target)
      and target >= 1
      and target <= #cfg.provider_names
    ) or (type(target) == "string" and resolved[target] ~= nil)
    assert(
      ok_target,
      string.format(
        "gerty: config.prompt_keys['%s'] must be a 1-based provider index "
          .. "(1-%d) or one of: %s",
        lhs,
        #cfg.provider_names,
        table.concat(cfg.provider_names, ", ")
      )
    )
  end

  -- A wrong type here is accepted silently and then fails deep inside an
  -- operation, as arithmetic on a string or a concat of a number. Catching it
  -- at setup() is the whole point of validating anything here.
  local function check(value, want, what)
    assert(
      type(value) == want,
      string.format(
        "gerty: config.%s must be a %s, got %s",
        what,
        want,
        type(value)
      )
    )
  end
  check(cfg.context_lines, "number", "context_lines")
  check(cfg.spinner_interval, "number", "spinner_interval")
  check(cfg.prompt_highlight, "boolean", "prompt_highlight")
  check(cfg.prompt_completion, "boolean", "prompt_completion")
  check(cfg.replace_explain, "boolean", "replace_explain")
  check(cfg.language.context_lines, "number", "language.context_lines")
  check(cfg.language.source, "string", "language.source")
  check(cfg.language.target, "string", "language.target")
  check(cfg.language.learner_level, "string", "language.learner_level")
  check(cfg.dictionary.command, "table", "dictionary.command")
  assert(
    #cfg.dictionary.command > 0,
    "gerty: config.dictionary.command must not be empty"
  )

  for _, preset in ipairs(cfg.language_presets) do
    assert(
      type(preset) == "table" and preset.source and preset.target,
      "gerty: every config.language_presets entry needs a source and a target"
    )
  end

  return cfg
end

return M
