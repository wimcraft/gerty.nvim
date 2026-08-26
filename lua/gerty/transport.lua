--- The one place that knows how a prompt reaches a model.
---
--- Prompt builders return a transport-neutral `gerty.Prompt` -- never a CLI
--- string and never an OpenAI message array -- so any op can be pointed at
--- any provider at runtime without the prompt shape becoming wrong. Turning
--- that into an argv or an HTTP body happens here, exactly once, and the
--- result is handed to jobs.lua so CLI, curl and dictionary processes all
--- share one ID space and one completion contract.

local jobs = require("gerty.jobs")

--- Builds a provider's command without trusting it. A custom `build_command`
--- is user code: it can throw, and it can return something that is not a
--- command at all. Either way the caller has a spinner up already, so this has
--- to come back as a value rather than as an exception.
--- @param provider gerty.ResolvedProvider
--- @param opts gerty.CommandOpts
--- @return string[]|nil cmd
--- @return string|nil error
local function build(provider, opts)
  local ok, cmd = pcall(provider.build_command, provider, opts)
  if not ok then
    return nil, tostring(cmd)
  end
  if type(cmd) ~= "table" or #cmd == 0 or type(cmd[1]) ~= "string" then
    return nil,
      string.format(
        "provider '%s' build_command returned %s, expected a non-empty list of strings",
        tostring(provider.alias or provider.name),
        type(cmd) == "table" and "an empty or malformed list" or type(cmd)
      )
  end
  return cmd, nil
end

--- `response_field` names the JSON key the answer should arrive in. It is set
--- by the op that built the prompt (see prompt.lua for why the NAME does half
--- the work), and it is honoured only where it can be: an OpenAI-compatible
--- server compiles it into a decoding grammar, a CLI ignores it entirely.
---
--- `response_prose` says whether the answer is prose (default) or code. It
--- controls the leading-space sentinel and how the answer is trimmed -- see
--- `json_schema()` and `decode_openai()` below.
---
--- @class gerty.Prompt
--- @field system string|nil instructions about the task, not the input
--- @field user string the input the model acts on
--- @field response_field string|nil JSON key to constrain and unwrap
--- @field response_prose boolean|nil false for code answers; defaults true

--- @class gerty.SendOpts
--- @field model string|nil overrides the provider's model for this call only
--- @field read_only boolean|nil deny file-mutating tools (CLI providers)
--- @field on_stdout fun(line: string)|nil streamed lines, CLI providers only
--- @field on_exit fun(result: gerty.JobResult) called exactly once

local M = {}

--- @param provider gerty.ResolvedProvider
--- @return boolean whether the provider can run tools against the repository
function M.is_agentic(provider)
  if provider.capabilities == nil then
    return true
  end
  return provider.capabilities.agentic ~= false
end

--- A CLI takes one blob of text, so a system prompt has to be folded into it.
--- With no system prompt the user text is passed through byte for byte, which
--- is what `replace`/`explain`/`ask` have always sent.
--- @param prompt gerty.Prompt
--- @return string
function M.render_cli(prompt)
  if prompt.system == nil or prompt.system == "" then
    return prompt.user
  end
  return string.format(
    "<system_instruction>\n%s\n</system_instruction>\n\n%s",
    prompt.system,
    prompt.user
  )
end

--- @param prompt gerty.Prompt
--- @return { role: string, content: string }[]
function M.render_messages(prompt)
  local messages = {}
  if prompt.system and prompt.system ~= "" then
    table.insert(messages, { role = "system", content = prompt.system })
  end
  table.insert(messages, { role = "user", content = prompt.user })
  return messages
end

--- Constrained decoding, and the single most load-bearing thing in this file.
---
--- The server compiles this schema into a decoding grammar, which is what
--- stops a reasoning-tuned local model prefacing its answer with a plan ("The
--- user wants me to...") and burying the real answer at the end. Prompt
--- wording and thinking toggles are suggestions the model can and does
--- ignore; a grammar is not. It is a **latency** feature as much as a
--- correctness one -- tokens spent narrating are tokens not spent answering,
--- and a translation that took ~15s answers in ~1.5s once it cannot narrate.
---
--- `pattern = "^ "` is not cosmetic, and it is what makes the schema usable
--- for prose at all. Without it, output that BEGINS with a quotation mark
--- (all novel dialogue) is silently truncated: the model reuses the grammar's
--- own string-opening `"` as the dialogue's opening quote, and the dialogue's
--- closing quote then ends the string. Valid JSON, `finish_reason: "stop"`,
--- everything after the first line of dialogue gone -- 0/15, and unfixable by
--- instruction, because the model never *chose* to emit that quote. Quotes
--- mid-string are escaped correctly; the collision only ever happens at
--- position 0.
---
--- Forcing ANY non-quote character into position 0 defuses it, but almost
--- everything gets interpreted: `"> "` closed an imaginary `</grammar_notes>`
--- tag; `"~ "`/`"@ "` made the model describe the marker; `"- "` broke
--- translate 0/4; `"= "` leaked LaTeX `\text{}`; `"EN: "` silently dropped the
--- dialogue quotes; `"Oh, "`/`"Well, "` were absorbed grammatically and
--- rewrote the line; `"¡"` switched the output language to Spanish; `"* "` is
--- a regex metacharacter and fails to compile. A single space is the one
--- genuinely inert choice -- not markup, not maths, not a word that can be
--- absorbed into the sentence after it, not a metacharacter -- and
--- `decode_openai` removes it again.
---
--- Re-examined and KEPT after the closing-instruction fix in prompt.lua made
--- it unnecessary for *completeness*, because it is still what preserves
--- dialogue quotes: multi-quote input scored 6/6 with it and **0/6** without,
--- where the model dodged the same delimiter collision by silently dropping
--- the quotation marks instead of truncating. Same conflict, quieter symptom.
---
--- Code answers (`response_prose = false`) get the schema WITHOUT the
--- sentinel: significant leading whitespace is the whole point of a code
--- replacement, and the trim that removes the sentinel would remove the first
--- line's indentation with it.
---
--- @param field string
--- @param prose boolean
--- @return table
local function json_schema(field, prose)
  local property = { type = "string" }
  if prose then
    property.pattern = "^ "
  end
  return {
    type = "object",
    properties = { [field] = property },
    required = { field },
    additionalProperties = false,
  }
end

--- @param prompt gerty.Prompt
--- @return boolean
local function is_prose(prompt)
  return prompt.response_prose ~= false
end

--- The layered decoding: transport failure, then malformed JSON, then an
--- API-level error object, then an unexpected shape, then a technically-valid
--- but empty answer -- each with a message that says which of those happened.
--- @param raw string
--- @param provider gerty.ResolvedProvider
--- @param prompt gerty.Prompt
--- @return gerty.JobResult
function M.decode_openai(raw, provider, prompt)
  local ok, resp = pcall(vim.json.decode, raw)
  if not ok or type(resp) ~= "table" then
    return {
      status = "error",
      output = raw,
      error = "malformed JSON response from " .. tostring(provider.endpoint),
    }
  end
  if type(resp.error) == "table" and resp.error.message then
    return {
      status = "error",
      output = raw,
      error = tostring(resp.error.message),
    }
  end

  local choice = type(resp.choices) == "table" and resp.choices[1] or nil
  local message = type(choice) == "table" and choice.message or nil
  local content = type(message) == "table" and message.content or nil
  if type(content) ~= "string" then
    return { status = "error", output = raw, error = "unexpected response shape" }
  end

  -- Unwrap the schema's payload field. A server that ignored `response_format`
  -- hands back prose, which will not parse -- keep that as-is rather than
  -- failing, so the only cost of an unsupported endpoint is the old behaviour.
  local field = prompt.response_field
  if field then
    local decoded_ok, parsed = pcall(vim.json.decode, content)
    if
      decoded_ok
      and type(parsed) == "table"
      and type(parsed[field]) == "string"
    then
      content = parsed[field]
    end
  end

  if is_prose(prompt) then
    -- also removes the leading-space sentinel from json_schema()
    content = vim.trim(content)
  else
    -- code: blank lines and trailing whitespace go, the first line's
    -- indentation stays -- it is the replacement's own
    content = content:gsub("^\n+", ""):gsub("%s+$", "")
  end

  if content == "" then
    return { status = "error", output = raw, error = "empty response" }
  end
  return { status = "ok", output = content }
end

--- @param provider gerty.ResolvedProvider
--- @param prompt gerty.Prompt
--- @param opts gerty.SendOpts
--- @return number id
local function send_openai(provider, prompt, opts)
  local payload = {
    model = provider.model,
    temperature = provider.temperature,
    stream = false,
    messages = M.render_messages(prompt),
  }

  -- The op said how it wants to be answered; this is where that becomes a
  -- grammar. No config line asks for it -- every chat endpoint gets it, so it
  -- can neither go missing on a provider nor be applied with a field name
  -- belonging to a different op. `json_schema = false` on the provider opts
  -- out for a server the grammar hurts.
  if provider.json_schema ~= false and prompt.response_field then
    payload.response_format = {
      type = "json_schema",
      json_schema = {
        name = "gerty",
        strict = true,
        schema = json_schema(prompt.response_field, is_prose(prompt)),
      },
    }
  end
  payload.chat_template_kwargs = provider.chat_template_kwargs
  local body = vim.json.encode(payload)

  local cmd, build_error = build(provider, { read_only = opts.read_only })
  if not cmd then
    return jobs.fail(build_error, opts.on_exit)
  end

  return jobs.spawn(cmd, {
    stdin = body,
    -- curl emits the whole JSON body at once; feeding that to the spinner
    -- would just flash a wall of braces, so nothing is streamed here
    on_exit = function(result)
      if result.status ~= "ok" then
        if result.status == "error" then
          result.error = string.format(
            "%s (endpoint %s)",
            result.error or "no response",
            tostring(provider.endpoint)
          )
        end
        opts.on_exit(result)
        return
      end
      opts.on_exit(M.decode_openai(result.output, provider, prompt))
    end,
  })
end

--- A per-call `model` is a one-off override, so it must not be written back
--- onto the shared provider -- select_model() is the thing that changes what a
--- provider currently points at. A shallow copy with the model swapped keeps
--- build_command reading one object.
--- @param provider gerty.ResolvedProvider
--- @param model string|nil
--- @return gerty.ResolvedProvider
local function for_call(provider, model)
  if model == nil or model == provider.model then
    return provider
  end
  return vim.tbl_extend("keep", { model = model }, provider)
end

--- Never throws. Every failure -- including a custom provider whose
--- `build_command` raises -- arrives through `on_exit`, because the caller has
--- already attached a spinner by the time this runs and an exception here
--- would strand it with no id to cancel.
--- @param provider gerty.ResolvedProvider
--- @param prompt gerty.Prompt
--- @param opts gerty.SendOpts
--- @return number id the jobs.lua id, for cancellation and UI bookkeeping
function M.send(provider, prompt, opts)
  provider = for_call(provider, opts.model)

  if provider.transport == "openai_compat" then
    return send_openai(provider, prompt, opts)
  end

  local cmd, build_error = build(provider, { read_only = opts.read_only })
  if not cmd then
    return jobs.fail(build_error, opts.on_exit)
  end
  cmd = vim.deepcopy(cmd)
  table.insert(cmd, M.render_cli(prompt))

  return jobs.spawn(cmd, {
    on_stdout = opts.on_stdout,
    on_exit = opts.on_exit,
  })
end

return M
