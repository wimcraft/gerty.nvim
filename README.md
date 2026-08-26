# gerty.nvim

A small, understandable AI-editing plugin for Neovim. Async, non-blocking,
surrounds the line you're working on with a status while it runs — so you
can keep coding or reviewing elsewhere in the meantime.

Named after GERTY, the quiet assistant AI from *Moon* — not a co-pilot that
takes over, just something that helps and gets out of the way.

This is a deliberately stripped-down alternative to
[ThePrimeagen/99](https://github.com/ThePrimeagen/99): same core mechanism
(async subprocess + temp-file output protocol + per-line virtual-text
status), a fraction of the surface area — see "What's intentionally not here"
below for what was cut.

## How it works

- `replace` (visual mode): select code, describe the change, and only that
  selection is rewritten in your buffer. On a CLI provider the model is *asked*
  to write its replacement to a temp file and touch nothing else — see the
  table below for what that does and does not guarantee. On a local chat model
  it has no file access at all.
- `explain` (visual mode): select code, ask a question about it. The model
  may read the **whole repository** to answer — the definitions it depends
  on, its callers, its tests — but the file-writing tools are denied at the
  CLI level, so it can't change anything. The answer opens in a scratch
  float, not in your buffer.
- `ask`: describe a task, the model runs as a full agent with its own tools
  and may edit any file it needs to — like running `pi`/`claude` yourself,
  just without leaving the editor or blocking it.
- `translate` (visual mode): select foreign-language text, get the
  translation in a float. The surrounding lines go along as **context the
  model is told not to translate** — only to disambiguate pronouns, gender,
  register and idioms with.
- `gloss` (visual mode): the grammar/vocabulary breakdown of the selection
  for a learner at the configured level. Type an instruction at the prompt to
  ask something else about the same selection instead.
- `word` (normal mode): dictionary lookup of the word under the cursor via
  `trans` (translate-shell). No model involved, so it's instant.
- Everything runs through one job runner (`vim.system()`, fully async) with a
  spinner + the latest line of output as virtual text above your cursor until
  the request finishes. `cancel_all()` covers every op, dictionary lookups
  included, and a cancelled request reports itself as cancelled rather than
  as a failure.

`translate` and `gloss` never write to your buffer, whichever provider they
end up on: routed to a CLI they run with the same read-only tool denylist
`explain` uses.

## Requirements

- **Neovim 0.10+** — gerty uses `vim.system`, `vim.uv`, `vim.iter` and
  `getregion()`. On 0.9 it will fail with a nil-index error rather than a
  useful message.
- **`curl`** — only if you point it at a local chat model.
- **At least one provider**: the [`pi`](https://pi.dev) CLI, the
  [`claude`](https://docs.claude.com/en/docs/claude-code) CLI, or an
  OpenAI-compatible server such as LM Studio or Ollama. gerty runs whichever
  you already have; it ships no API client and holds no API keys.
- **[translate-shell](https://github.com/soimort/translate-shell)** (`trans`) —
  only for `word`, the dictionary lookup. Everything else works without it.

## A word about `ask`

Four of the five model operations are constrained, and deliberately so:

| op | your buffer | the rest of your files |
| --- | --- | --- |
| `explain` | never written | **enforced**: file *and* shell tools denied at the CLI |
| `translate` / `gloss` | never written | **enforced**: same denylist |
| `replace` | only the selected lines | **prompt-level only** on a CLI provider; enforced on a chat model, which has no tools |
| **`ask`** | not written directly | **unrestricted, no confirmation** |

Two of those deserve spelling out.

**`replace` containment is a request, not a sandbox.** The temp-file protocol
means a well-behaved model has no reason to touch anything else, and in
practice they don't. But a CLI provider still runs `replace` with its tools
available — it has to, since writing the temp file *is* a file write — so the
"touch nothing else" part is an instruction the model follows, not a
restriction it operates under. A model that misbehaves, or is talked into
misbehaving by text inside the code you selected, can write elsewhere. If you
want `replace` to be structurally unable to do that, point it at a local chat
model: those have no tools at all, and the replacement comes back as text.

**`ask` runs with approval prompts disabled** — `claude
--dangerously-skip-permissions`, `pi --approve` — because being asked to
confirm inside a `--print` subprocess you cannot see is not something you can
answer. That makes it exactly as powerful as running that CLI yourself, which
is the point of it; it also means it can edit anything, and you will not be
asked first.

It also inherits Neovim's **current working directory**, not the project root
of the file you happen to be editing. If you started `nvim` from your home
directory, that is the directory `ask` is told it is working in. Check `:pwd`
before using it on anything you care about.

If that is not what you want, don't map `ask`. `explain`, `translate` and
`gloss` do not use those flags and are unaffected.

## Install

```lua
{
  "rfist/gerty.nvim",
  config = function()
    local gerty = require("gerty")
    gerty.setup({
      -- declare the providers you have and the models each one can reach.
      -- No roles, no "this one is for translation": every model here can
      -- serve every op. `type` defaults to the alias, so `pi` and `claude`
      -- need nothing but their models.
      providers = {
        pi = { billing = "Codex subscription", models = { "openai-codex/gpt-5.6-luna" } },
        claude = {
          billing = "Claude subscription",
          models = { "claude-sonnet-5", "claude-opus-5" },
        },
        -- a local chat model. No JSON/schema tuning needed here -- gerty
        -- handles that per operation. `local` is a Lua keyword, hence [""].
        ["local"] = {
          type = "lmstudio", -- localhost:1234; `endpoint =` overrides
          billing = "local, free",
          models = { "google/gemma-4-e4b", "qwen/qwen3-1.7b" },
        },
      },
      default = "pi", -- switch at runtime with select_model()
      -- per-operation defaults, overriding `default` for that op only
      op_defaults = { translate = "local", gloss = "local" },
      language = { source = "de", target = "en", context_lines = 5, learner_level = "intermediate" },
      language_presets = { { source = "de", target = "en" }, { source = "pl", target = "en" } },
      dictionary = { command = { "trans", "-b" } },
      skills = {
        "~/.config/nvim/skills/", -- dirs containing <name>/SKILL.md
      },
    })

    vim.keymap.set("v", "<leader>gr", function()
      gerty.replace()
    end)

    -- explain the selection, always on the Claude CLI
    vim.keymap.set("v", "<leader>ge", function()
      gerty.explain({ provider = "claude" })
    end)

    vim.keymap.set("n", "<leader>ga", function()
      gerty.ask()
    end)

    -- language ops: visual for translate/gloss, normal for word
    vim.keymap.set("v", "<leader>gt", function()
      gerty.translate()
    end)

    vim.keymap.set("v", "<leader>gg", function()
      gerty.gloss()
    end)

    vim.keymap.set("n", "<leader>gw", function()
      gerty.word()
    end)

    vim.keymap.set("n", "<leader>gl", function()
      gerty.select_language()
    end)

    vim.keymap.set("n", "<leader>gA", function()
      gerty.select_model()
    end)

    vim.keymap.set("n", "<leader>gx", function()
      gerty.cancel_all()
    end)
  end,
}
```

## Config

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `providers` | `table<string, gerty.ProviderSpec>` | `{ pi = {} }` | alias → provider; see below |
| `default` | `string?` | first alias, alphabetically | the provider used when a call names none |
| `op_defaults` | `table<string, string>` | `{}` | per-operation default alias, overriding `default` |
| `skills` | `string[]` | `{}` | dirs scanned for `<name>/SKILL.md` |
| `context_lines` | `number` | `40` | lines of surrounding context sent with `replace` |
| `spinner_interval` | `number` | `120` | ms between spinner frame updates |
| `language.source` | `string` | `"de"` | language code the language ops read |
| `language.target` | `string` | `"en"` | language code they answer in |
| `language.context_lines` | `number` | `5` | lines around the selection sent for disambiguation |
| `language.learner_level` | `string` | `"intermediate"` | audience `gloss` writes for |
| `language_presets` | `{source,target}[]` | `{}` | choices offered by `select_language()` |
| `dictionary.command` | `string[]` | `{ "trans", "-b" }` | argv prefix for `word()`; pair and word are appended |
| `dictionary.source` / `.target` | `string?` | `language.*` | override the pair for `word()` only |

Per provider:

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `type` | `string?` | the alias | `"pi"`, `"claude"`, `"lmstudio"`, `"ollama"`, `"openai_compat"`, or a type table |
| `models` | `(string \| {id,name?,billing?})[]` | `{}` | offered by `select_model()` |
| `model` | `string?` | `models[1]` | the current model |
| `billing` | `string?` | — | display-only tag, inherited by this provider's models |
| `endpoint` | `string?` | the type's | chat endpoints only |
| `temperature` | `number?` | `0.2` for `lmstudio`/`ollama` | chat endpoints only |
| `json_schema` | `boolean?` | `true` | set `false` to skip constrained decoding |
| `chat_template_kwargs` | `table?` | — | e.g. `{ enable_thinking = true }` |
| `extra_args` | `string[]` | `{}` | appended to the CLI command before the prompt |
| `build_command` | `function?` | the type's | full escape hatch |

`op_defaults` keys are the five operations (`replace`, `explain`, `ask`,
`translate`, `gloss`) — a typo, or a name that isn't a configured provider,
fails at `setup()` rather than at the first call. `word` takes no provider: it
runs a dictionary binary, not a model.

## Providers and models

A provider is a mechanism (`pi`, `claude`, an OpenAI-compatible endpoint) plus
the models you can point it at. The alias is what you type as `$alias` and see
in every picker:

```lua
gerty.setup({
  providers = {
    pi = {
      billing = "Codex subscription",
      models = {
        "openai-codex/gpt-5.6-luna",
        -- same CLI, different account paying -- hence the override
        { id = "kilo/deepseek/deepseek-v4-pro", name = "DeepSeek V4 Pro",
          billing = "Kilo, pay-per-token" },
      },
    },
    claude = { models = { "claude-sonnet-5", "claude-opus-5" } },
  },
  default = "pi",
})
```

**There are no roles.** Every model can serve every op; some are simply better
at some things, which is a judgement you make when you pick one, not something
the config encodes. `select_model()` offers one flat list across every provider
and sets both the default provider and that provider's model in a single
choice. Ops with their own `op_defaults` entry are deliberately unaffected —
switching the default to Claude shouldn't drag translation off the local model
you routed it to on purpose.

`billing` is display-only; gerty never reads it to decide anything. It exists
because `pi` pointed at a gateway's `claude-sonnet-5` and the `claude` CLI on
your subscription would otherwise render identically in every picker, despite
one being flat-rate and the other metered.

Every op takes a per-call `provider = "alias"` that overrides the default for
that call only, and a per-call `model = "..."` on top of that.

### Local models

`lmstudio` and `ollama` are presets over `openai_compat` with the usual local
endpoints filled in:

```lua
["local"] = { type = "lmstudio", models = { "google/gemma-4-e4b" } },
["box"]   = { type = "ollama", endpoint = "http://box:11434/v1/chat/completions" },
```

**They need no per-operation tuning.** gerty constrains an OpenAI-compatible
endpoint to a JSON field named after the op doing the asking — `translation`,
`grammar_notes`, `answer`, `replacement` — which is what stops a
reasoning-tuned small model opening with its own plan and burying the answer at
the end. That is a latency win as much as a correctness one. The field name is
load-bearing and is set by the op, not by you; see the schema comment in
`lua/gerty/transport.lua` for the measurements behind it. `json_schema = false`
opts out for a server the grammar hurts.

A server that ignores `response_format` degrades to plain text rather than
erroring. This targets **local, unauthenticated** endpoints only — there's no
auth-header or secret handling, so don't aim it at the public internet.

Chat-only providers have no tools, so `ask` refuses them up front rather than
opening a spinner for a request that can't work. Everything else adapts:
`replace` gets the code back directly instead of through a temp file, and
`explain` answers from the selection instead of from the repository.

## API

- `gerty.setup(opts)`
- `gerty.replace({ instruction?, model?, provider? })` — call from visual mode;
  prompts via `vim.ui.input` if `instruction` isn't given.
- `gerty.explain({ instruction?, model?, provider? })` — visual mode, read-only.
  An empty prompt defaults to "explain what this code does, why it exists,
  and how it's used elsewhere in the repository".
- `gerty.ask({ instruction?, model?, provider? })` — agentic, no selection needed.
- `gerty.translate({ model?, provider?, source?, target?, context_lines? })` —
  visual mode, answer in a float, buffer never touched.
- `gerty.gloss({ instruction?, model?, provider?, source?, target?, learner_level?, context_lines? })`
  — visual mode. An empty (or whitespace-only) prompt gives the default
  grammar/vocabulary breakdown; anything typed becomes the instruction.
- `gerty.word({ word?, source?, target? })` — dictionary lookup of the word
  under the cursor. No model, no provider.
- `gerty.select_model({ provider? })` — the everyday switcher: one flat list
  of every model on every provider. Picking one sets both the default provider
  and that provider's current model. Pass `provider` to narrow the list.
- `gerty.set_provider(alias)` / `gerty.get_provider(op?)` — the global default,
  and what a given op currently resolves to.
- `gerty.set_language({ source?, target?, context_lines?, learner_level? })` /
  `gerty.get_language()` / `gerty.select_language()` — swap the language pair
  mid-session without touching your config. `select_language()` picks from
  `language_presets`.
- `gerty.cancel_all()` — kills every in-flight request and clears their status.
- `gerty.refresh_skills()` — re-scan `skills` dirs after adding a new one.
- `gerty.provider_types` — the built-in types (`pi`, `claude`, `lmstudio`,
  `ollama`, `openai_compat`), for reference when writing your own.

Every runtime setter is in-memory and session-scoped: nothing is written back
to your config, and nothing survives a restart.

## Switching providers inline

At any prompt that takes text (`replace`, `explain`, `ask`, `gloss`), a
leading `$alias` picks the provider for that one call — above the per-op
default, above the global one:

```
Ask: $claude how do I use this function and what does it return?
Gloss: $local why is this Präteritum?
```

A small reference window opens next to the prompt listing what you can type:

```
Available providers:
  $claude (claude-sonnet-5) [Claude subscription]
  $local (google/gemma-4-e4b) [local, free]
  $pi (openai-codex/gpt-5.6-luna) [Codex subscription]
Available skills:
  #mentor
  #version-bump
```

It's a static card, not a completion popup — it never takes focus and closes
when the prompt does. `$notaprovider` is left in your text untouched rather
than silently eaten.

`$alias` picks a provider, not a model — model ids like
`kilo/deepseek/deepseek-v4-pro` are not things you want to type at a prompt.
Use `select_model()` or a per-call `model = "..."` for that.

## Skills

Type `#name` anywhere in a prompt and, if `<skills-dir>/name/SKILL.md`
exists, its contents get injected as extra context:

```
#refactor extract this into a helper function
```

## Languages

`translate`, `gloss` and `word` share one language config, and the pair is
switchable at runtime:

```lua
gerty.set_language({ source = "pl", target = "uk" })  -- session-only
gerty.select_language()                               -- pick from language_presets
gerty.translate({ source = "pl", target = "uk" })     -- this call only
```

`word()` shells out to [translate-shell](https://github.com/soimort/translate-shell)
(`trans -b de:en <word>`) rather than a model, because "what does this word
mean" doesn't need one. Point `dictionary.command` at something else, or use
`{ "trans", "-d", "-no-ansi" }` for full dictionary entries instead of the
one-line gloss.

## Writing your own provider type

If your CLI isn't `pi` or `claude`, hand a type table to `type` (or override
just `build_command` on an existing type):

```lua
--- @type gerty.ProviderType
local my_type = {
  name = "some-cli",
  transport = "cli",                 -- or "openai_compat"
  capabilities = { agentic = true },
  build_command = function(provider, opts)
    local cmd = { "some-cli", "--flag" }
    -- opts.read_only is set by `explain`: deny this CLI's file-writing tools
    if opts and opts.read_only then
      vim.list_extend(cmd, { "--deny-tools", "edit,write,shell" })
    end
    if provider.model then
      vim.list_extend(cmd, { "--model", provider.model })
    end
    vim.list_extend(cmd, provider.extra_args)
    return cmd -- prompt is appended as the final positional arg
  end,
}

gerty.setup({
  providers = { mine = { type = my_type, models = { "a", "b" } } },
})
```

`build_command` receives the whole resolved provider, so a per-call `model`
override reaches it without any extra plumbing.

If you implement `read_only`, **deny the shell too**, not just the edit tools:
a model that can't call `Write` will cheerfully write the file with a shell
heredoc instead. That's not hypothetical — it's how the first version of this
was caught.

## Tests

```bash
make test        # or: nvim -l tests/run.lua
```

66 tests, a few seconds, no dependencies — the suite needs nothing the plugin
doesn't already need. Subprocesses are mocked, so nothing is spawned and no
model is called.

```bash
make test-live   # or: GERTY_TEST_LIVE=1 nvim -l tests/run.lua
```

Additionally runs three tests against a real OpenAI-compatible server
(LM Studio's endpoint by default; override with `GERTY_TEST_LIVE_ENDPOINT` and
`GERTY_TEST_LIVE_MODEL`). These are separate because they are the one thing a
mock cannot check: whether a real server honours the decoding grammar. If you
change anything about how a local model is prompted, run them.

## Design docs

- `openspec/specs/` — the behavioural specification, 13 capabilities and 79
  requirements written as `WHEN`/`THEN` scenarios. Start here to understand
  what gerty guarantees. Browse with [OpenSpec](https://github.com/Fission-AI/OpenSpec)
  (`openspec show <capability>`) or just read the Markdown.
Most of the prompt wording, and all of the local-model decoding behaviour, was
arrived at by measurement rather than by taste. Where a scenario in those specs
looks arbitrary, it usually is not — the reasoning is in the comment above the
code it governs. `lua/gerty/transport.lua` in particular is worth reading
before changing anything about how a local model is prompted.

## What's intentionally not here

No request history, no log viewer, no quickfix/search op, no telescope/fzf
model picker, no live completion popup for `$providers`/`#skills`/`@files` (just
the static hint card), no treesitter function-scope targeting (so `explain`
takes a line-wise visual range — you select the function yourself). All were
in the original; none survived the cut for v1. `replace` is also still
deliberately line-based, unlike `translate`/`gloss`, which read the exact
characterwise/blockwise selection. `openspec/specs/` records the reasoning as
scenarios, and the open issues track what may yet change.
