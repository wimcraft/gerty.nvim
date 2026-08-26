--- The constrained-decoding path. These are the regression tests that matter
--- most: the schema is what keeps a local model from narrating instead of
--- answering, and every property asserted here was arrived at by measurement.

local T = require("tests.helpers")
local config = require("gerty.config")
local prompt = require("gerty.prompt")
local transport = require("gerty.transport")

local cfg = config.resolve({
  providers = {
    pi = { models = { "some-model" } },
    lm = { type = "lmstudio", models = { "a-local-model" } },
    plain = { type = "lmstudio", models = { "m" }, json_schema = false },
  },
})
local lm, pi, plain = cfg.providers.lm, cfg.providers.pi, cfg.providers.plain
local noop = { on_exit = function() end }

local function body_of(mock)
  return vim.json.decode(mock.last.stdin)
end

local function schema_of(mock)
  return body_of(mock).response_format.json_schema.schema
end

local function a_translate()
  return prompt.translate({
    source = "de",
    target = "en",
    before = T.de.before,
    after = T.de.after,
    selection = T.de.plain,
  })
end

T.test("a translate request is constrained to a translation field", function()
  local mock = T.mock_jobs()
  transport.send(lm, a_translate(), noop)
  local schema = schema_of(mock)
  T.ok(schema.properties.translation, "field is `translation`")
  T.eq(schema.properties.translation.pattern, "^ ", "prose sentinel")
  T.eq(schema.required[1], "translation")
  T.eq(schema.additionalProperties, false)
  T.eq(body_of(mock).response_format.json_schema.strict, true)
  T.unmock_jobs(mock)
end)

T.test("gloss gets its own field on the very same provider", function()
  local mock = T.mock_jobs()
  transport.send(lm, prompt.gloss({
    source = "de", target = "en", learner_level = "intermediate",
    before = "", after = "", selection = T.de.plain,
  }), noop)
  T.ok(schema_of(mock).properties.grammar_notes, "field is `grammar_notes`")
  T.ok(
    schema_of(mock).properties.translation == nil,
    "a gloss constrained to `translation` returns a translation"
  )
  T.unmock_jobs(mock)
end)

T.test("explain is constrained to an answer field", function()
  local mock = T.mock_jobs()
  transport.send(lm, prompt.explain({
    instruction = "what", cwd = "/tmp", file = "a.lua", filetype = "lua",
    start_line = 1, end_line = 2, selection = "x", skills = {}, agentic = false,
  }), noop)
  T.ok(schema_of(mock).properties.answer)
  T.unmock_jobs(mock)
end)

T.test("a code answer gets no prose sentinel", function()
  local mock = T.mock_jobs()
  transport.send(lm, prompt.replace({
    instruction = "x", filetype = "lua", selection = "y", context = "",
    skills = {}, agentic = false,
  }), noop)
  local schema = schema_of(mock)
  T.ok(schema.properties.replacement, "field is `replacement`")
  T.eq(
    schema.properties.replacement.pattern,
    nil,
    "the sentinel's trim would eat the first line's indentation"
  )
  T.unmock_jobs(mock)
end)

T.test("ask declares no field, so nothing is constrained", function()
  local mock = T.mock_jobs()
  transport.send(lm, prompt.ask({ instruction = "x", cwd = "/", file = "f", skills = {} }), noop)
  T.eq(body_of(mock).response_format, nil)
  T.unmock_jobs(mock)
end)

T.test("json_schema = false opts a provider out", function()
  local mock = T.mock_jobs()
  transport.send(plain, a_translate(), noop)
  T.eq(body_of(mock).response_format, nil)
  T.unmock_jobs(mock)
end)

T.test("temperature and model reach the request body", function()
  local mock = T.mock_jobs()
  transport.send(lm, a_translate(), noop)
  T.eq(body_of(mock).model, "a-local-model")
  T.eq(body_of(mock).temperature, 0.2)
  T.unmock_jobs(mock)
end)

T.test("a CLI provider sends no body and appends the prompt to the argv", function()
  local mock = T.mock_jobs()
  transport.send(pi, a_translate(), noop)
  T.eq(mock.last.stdin, nil, "no HTTP body")
  T.eq(mock.last.cmd[1], "pi")
  T.ok(mock.last.cmd[#mock.last.cmd]:find(T.de.plain, 1, true), "prompt is the last argv entry")
  T.ok(vim.tbl_contains(mock.last.cmd, "some-model"), "model on the argv")
  T.unmock_jobs(mock)
end)

T.test("read_only denies the shell as well as the edit tools", function()
  local mock = T.mock_jobs()
  transport.send(pi, a_translate(), { read_only = true, on_exit = function() end })
  local argv = table.concat(mock.last.cmd, " ")
  T.ok(argv:find("bash", 1, true), "denying edit/write alone leaves a shell to write with")
  T.unmock_jobs(mock)
end)

T.test("a per-call model does not mutate the shared provider", function()
  local mock = T.mock_jobs()
  transport.send(pi, prompt.ask({ instruction = "x", cwd = "/", file = "f", skills = {} }), {
    model = "other-model",
    on_exit = function() end,
  })
  T.ok(vim.tbl_contains(mock.last.cmd, "other-model"), "override reached the argv")
  T.eq(pi.model, "some-model", "provider was mutated by a per-call override")
  T.unmock_jobs(mock)
end)

T.test("prose decoding drops the sentinel and keeps the quotes", function()
  local answer = '"That is my cup!" The waiter put down the tray and left.'
  local result = transport.decode_openai(
    T.chat_response(vim.json.encode({ translation = " " .. answer })),
    lm,
    { response_field = "translation" }
  )
  T.eq(result.status, "ok")
  T.eq(result.output, answer)
end)

T.test("code decoding preserves the first line's indentation", function()
  local result = transport.decode_openai(
    T.chat_response(vim.json.encode({ replacement = "\n    local total = 1\n    return total\n\n" })),
    lm,
    { response_field = "replacement", response_prose = false }
  )
  T.eq(result.output, "    local total = 1\n    return total")
end)

T.test("a server that ignores the schema degrades to plain text", function()
  local result = transport.decode_openai(
    T.chat_response("just plain prose"),
    lm,
    { response_field = "translation" }
  )
  T.eq(result.status, "ok")
  T.eq(result.output, "just plain prose")
end)

T.test("failures say which kind they were", function()
  local malformed = transport.decode_openai("not json", lm, {})
  T.eq(malformed.status, "error")
  T.ok(malformed.error:find("malformed JSON", 1, true))

  local api_error = transport.decode_openai(
    vim.json.encode({ error = { message = "model not loaded" } }), lm, {}
  )
  T.eq(api_error.error, "model not loaded")

  local wrong_shape = transport.decode_openai(vim.json.encode({ nope = true }), lm, {})
  T.ok(wrong_shape.error:find("unexpected response shape", 1, true))

  local empty = transport.decode_openai(T.chat_response("   "), lm, {})
  T.ok(empty.error:find("empty response", 1, true))
end)

T.test("a CLI prompt folds the system instruction into the text", function()
  local rendered = transport.render_cli({ system = "be terse", user = "hello" })
  T.ok(rendered:find("be terse", 1, true))
  T.ok(rendered:find("hello", 1, true))
  T.eq(transport.render_cli({ user = "hello" }), "hello", "no system: byte for byte")
end)
