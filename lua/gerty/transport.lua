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
--- controls how the answer is trimmed: prose is trimmed on both ends, code
--- keeps the leading whitespace that is its indentation.
---
--- `response_field_extra` names a SECOND JSON key alongside `response_field`,
--- for an op that wants two things back at once under one grammar -- `replace`
--- with a skill uses it for `{ replacement, explanation }`. Both keys are
--- required; the extra one is unwrapped onto `result.extra`, always trimmed as
--- prose regardless of `response_prose` (that flag governs the main field).
---
--- @class gerty.Prompt
--- @field system string|nil instructions about the task, not the input
--- @field user string the input the model acts on
--- @field response_field string|nil JSON key to constrain and unwrap
--- @field response_field_extra string|nil a second required key, unwrapped onto result.extra
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

--- Constrained decoding: the schema becomes a decoding grammar, which is what
--- stops a reasoning-tuned local model prefacing its answer with a plan ("The
--- user wants me to...") and burying the real answer at the end. Prompt wording
--- and thinking toggles are suggestions a model can and does ignore; a grammar
--- is not. It is a latency feature as much as a correctness one -- tokens spent
--- narrating are tokens not spent answering.
---
--- HISTORY, because this used to say the opposite. The schema carried
--- `pattern = "^ "`, forcing the answer to begin with a space. That existed to
--- stop a delimiter collision at position 0, where a model reusing the
--- grammar's own string-opening quote as the text's opening quote had its
--- answer truncated at the text's closing quote. It was measured as load-
--- bearing at the time: multi-quote input scored 6/6 with it and 0/6 without.
---
--- It has been REMOVED, on a later measurement that reversed the result. A
--- standalone leading space is off-distribution for a tokenizer that normally
--- merges the space into the following word, and constraining generation into
--- that rare token path derails it. On a real reported failure -- a line of
--- dialogue with an unbalanced opening quote -- the sentinel produced an EMPTY
--- translation 2 times in 6, and prefixed the rest with junk ("(") 4 times in
--- 6. Without it: 0 empty, 0 junk, 6/6 complete.
---
--- Crucially, quote preservation did NOT regress: quote-initial dialogue and a
--- multi-quote exchange both scored 6/6 with and without. What protects quotes
--- now is the closing instruction in prompt.lua, added after the sentinel was
--- and independently verified there. The sentinel had become a cost with no
--- remaining benefit.
---
--- The lesson worth keeping: a guard justified by measurement has to be
--- re-measured when the thing it guards against is fixed another way, or it
--- outlives its reason and starts causing the failure it was meant to prevent.
---
--- @param field string
--- @param extra string|nil a second required string key
--- @return table
local function json_schema(field, extra)
  local properties = { [field] = { type = "string" } }
  local required = { field }
  if extra then
    properties[extra] = { type = "string" }
    required[#required + 1] = extra
  end
  return {
    type = "object",
    properties = properties,
    required = required,
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
  --- Every failure names the endpoint it came from: with several providers
  --- configured, "empty response" on its own does not say which one.
  --- @param message string
  --- @return gerty.JobResult
  local function fail(message)
    return {
      status = "error",
      output = raw,
      error = string.format("%s (endpoint %s)", message, tostring(provider.endpoint)),
    }
  end

  if type(resp.error) == "table" and resp.error.message then
    return fail(tostring(resp.error.message))
  end

  local choice = type(resp.choices) == "table" and resp.choices[1] or nil
  local message = type(choice) == "table" and choice.message or nil
  local content = type(message) == "table" and message.content or nil
  if type(content) ~= "string" then
    return fail("unexpected response shape")
  end

  -- A response cut off at the token limit is not a successful answer. It
  -- matters most for `replace`, where accepting it writes half a statement
  -- into the buffer -- valid-looking, silently truncated, and indistinguishable
  -- from what the model meant to say.
  if choice.finish_reason == "length" then
    return fail("response was cut off at the model's token limit")
  end

  -- Unwrap the schema's payload field. A server that ignored `response_format`
  -- hands back prose, which will not parse -- keep that as-is rather than
  -- failing, so the only cost of an unsupported endpoint is the old behaviour.
  local extra
  local field = prompt.response_field
  if field then
    local decoded_ok, parsed = pcall(vim.json.decode, content)
    if
      decoded_ok
      and type(parsed) == "table"
      and type(parsed[field]) == "string"
    then
      local key = prompt.response_field_extra
      if key and type(parsed[key]) == "string" then
        local trimmed = vim.trim(parsed[key])
        extra = trimmed ~= "" and trimmed or nil
      end
      content = parsed[field]
    end
  end

  -- Control characters are never part of an answer, and a model constrained
  -- into an odd token path can emit one; rendered raw in a float it shows up
  -- as garbage like `^Z`. Tabs and newlines are legitimate, the rest are not.
  content = content:gsub("[%z\1-\8\11\12\14-\31\127]", "")

  if is_prose(prompt) then
    content = vim.trim(content)
  else
    -- code: blank lines and trailing whitespace go, the first line's
    -- indentation stays -- it is the replacement's own
    content = content:gsub("^\n+", ""):gsub("%s+$", "")
  end

  if content == "" then
    return fail("empty response")
  end
  return { status = "ok", output = content, extra = extra }
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
        schema = json_schema(
          prompt.response_field,
          prompt.response_field_extra
        ),
      },
    }
  end
  payload.chat_template_kwargs = provider.chat_template_kwargs
  -- chat_template_kwargs comes from user config and need not be encodable;
  -- the caller has a spinner up by now, so this cannot be allowed to throw
  local encoded, body = pcall(vim.json.encode, payload)
  if not encoded then
    return jobs.fail(
      "could not encode the request body: " .. tostring(body),
      opts.on_exit
    )
  end

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
