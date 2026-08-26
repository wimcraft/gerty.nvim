--- Provider *types*: the handful of mechanisms gerty knows how to talk to.
--- A type says how to turn a resolved provider into a command, plus two facts
--- about what that command can do. Everything user-facing -- which models are
--- available, which one is current, who's paying -- lives in the config's
--- `providers` map and is merged onto a type by config.resolve().
---
--- `transport` says how the prompt reaches the model: `"cli"` appends it as
--- the final positional argument (both `pi` and `claude` accept it that way),
--- `"openai_compat"` POSTs a chat-completions body over stdin. transport.lua
--- owns both conversions, so a prompt never has to know which one it's for.
---
--- `capabilities.agentic` says whether the model can run tools against the
--- repository. Only `ask` requires that -- it is *defined* as "edit whatever
--- files you need" -- and it refuses a chat-only provider up front rather than
--- opening a spinner for a request that cannot possibly work. Every other op
--- adapts instead: `replace` returns the replacement text directly rather than
--- writing it to a temp file, and `explain` answers from the selection rather
--- than from the repository. See prompt.lua, which swaps the wording to match
--- so a model is never told to read files it has no way of reading.
---
--- `opts.read_only` is set for ops that must never touch the working tree
--- (`explain`, and `translate`/`gloss` when they run on a CLI agent).
--- Providers translate it into whatever tool-denylist flag their CLI
--- understands; the prompt says the same thing in words, so a provider that
--- ignores the flag still degrades to prompt-level intent.

--- @class gerty.CommandOpts
--- @field read_only boolean|nil deny file-mutating tools for this run

--- @class gerty.ProviderCapabilities
--- @field agentic boolean can read/edit the repository with its own tools

--- A provider type. Fields here are defaults: anything a `gerty.ProviderSpec`
--- sets in the user's config wins, which is how one `lmstudio` type serves a
--- machine with a non-standard port.
--- @class gerty.ProviderType
--- @field name string identifies the mechanism in pickers/labels, e.g. "pi", "claude", "lmstudio" -- NOT the model and NOT which subscription pays for it (that's `billing`, since the same CLI can be pointed at a subscription-covered model or a pay-per-token gateway model depending entirely on which model string it's handed)
--- @field default_model string|nil used when the spec lists no models
--- @field transport "cli"|"openai_compat"
--- @field capabilities gerty.ProviderCapabilities
--- @field endpoint string|nil openai_compat only: the chat-completions URL
--- @field temperature number|nil openai_compat only
--- @field build_command fun(provider: gerty.ResolvedProvider, opts: gerty.CommandOpts|nil): string[]

local M = {}

-- https://pi.dev/docs/latest/usage
M.pi = {
  name = "pi",
  default_model = nil, -- let pi use its own configured default
  transport = "cli",
  capabilities = { agentic = true },
  build_command = function(provider, opts)
    local cmd = { "pi", "--print", "--approve" }
    if opts and opts.read_only then
      -- `bash` has to go too: denying only edit/write still leaves the model
      -- a shell to write files with, which it will happily use
      vim.list_extend(cmd, { "--exclude-tools", "edit,write,bash" })
    end
    if provider.model then
      vim.list_extend(cmd, { "--model", provider.model })
    end
    vim.list_extend(cmd, provider.extra_args)
    return cmd
  end,
}

M.claude = {
  name = "claude",
  default_model = "claude-sonnet-5",
  transport = "cli",
  capabilities = { agentic = true },
  build_command = function(provider, opts)
    local cmd = { "claude", "--dangerously-skip-permissions", "--print" }
    if opts and opts.read_only then
      -- deny rules win over --dangerously-skip-permissions. Bash has to be on
      -- the list: with only the edit tools denied the model reaches for a
      -- shell heredoc instead, which was verified to write files anyway.
      -- Read/Grep/Glob remain, which is all `explain` needs to walk the repo.
      vim.list_extend(
        cmd,
        { "--disallowedTools", "Edit,Write,NotebookEdit,Bash" }
      )
    end
    if provider.model then
      vim.list_extend(cmd, { "--model", provider.model })
    end
    vim.list_extend(cmd, provider.extra_args)
    return cmd
  end,
}

--- A plain chat model behind an OpenAI-compatible `/chat/completions`
--- endpoint -- LM Studio, Ollama's compat shim, llama.cpp's server. No tools,
--- so `ask` refuses it; every other op adapts (see the header comment).
---
--- These target **local, unauthenticated** endpoints only: no auth headers, no
--- secret handling. Point one at something on the public internet and the
--- request goes out unauthenticated.
---
--- @param spec { name: string, endpoint: string|nil, temperature: number|nil }
--- @return gerty.ProviderType
local function chat_endpoint(spec)
  return {
    name = spec.name,
    default_model = nil,
    transport = "openai_compat",
    capabilities = { agentic = false },
    endpoint = spec.endpoint,
    temperature = spec.temperature,
    -- the body goes in over stdin (`--data-binary @-`), so the command is the
    -- same for every request and carries no prompt text on the argv. The
    -- endpoint is read off the resolved provider, not captured here, so a
    -- config that overrides `endpoint` actually reaches curl.
    build_command = function(provider, _)
      local cmd = {
        "curl",
        "-sS",
        "-X",
        "POST",
        provider.endpoint,
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        "@-",
      }
      vim.list_extend(cmd, provider.extra_args)
      return cmd
    end,
  }
end

--- Any OpenAI-compatible server. Needs an explicit `endpoint` in the config.
M.openai_compat = chat_endpoint({ name = "openai_compat" })

--- LM Studio's default server address. `temperature = 0.2` because every op
--- that ends up here wants a faithful answer rather than an inventive one --
--- translation, gloss, explanation, a mechanical edit.
M.lmstudio = chat_endpoint({
  name = "lmstudio",
  endpoint = "http://localhost:1234/v1/chat/completions",
  temperature = 0.2,
})

--- Ollama's OpenAI compatibility shim. NOTE: it accepts
--- `response_format.json_schema` but its grammar compiler's `pattern` support
--- is weaker than LM Studio's -- see the schema comment in transport.lua for
--- what `pattern` is load-bearing for, and what happens when it is ignored.
M.ollama = chat_endpoint({
  name = "ollama",
  endpoint = "http://localhost:11434/v1/chat/completions",
  temperature = 0.2,
})

return M
