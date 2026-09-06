--- Opt-in tests that talk to a real local model. Skipped unless
--- GERTY_TEST_LIVE=1, so the default suite stays hermetic and fast.
---
--- Set GERTY_TEST_LIVE_ENDPOINT / GERTY_TEST_LIVE_MODEL to point at your own
--- server; the defaults are LM Studio's.
---
--- These exist because the schema in transport.lua is the one thing no mock
--- can verify: whether a real server actually honours it.

local T = require("tests.helpers")
local config = require("gerty.config")
local prompt = require("gerty.prompt")
local transport = require("gerty.transport")

if vim.env.GERTY_TEST_LIVE ~= "1" then
  io.write("  skip live tests (set GERTY_TEST_LIVE=1 to run)\n")
  return
end

local endpoint = vim.env.GERTY_TEST_LIVE_ENDPOINT
  or "http://localhost:1234/v1/chat/completions"
local model = vim.env.GERTY_TEST_LIVE_MODEL

local cfg = config.resolve({
  providers = { lm = { type = "lmstudio", endpoint = endpoint, models = model and { model } or nil } },
})
local lm = cfg.providers.lm

--- @param request gerty.Prompt
--- @return gerty.JobResult
local function ask(request)
  local result
  transport.send(lm, request, {
    read_only = true,
    on_exit = function(r) result = r end,
  })
  -- a cold model can take a while to load; the assertions, not the clock,
  -- decide whether this passed
  T.wait_for(function() return result ~= nil end, 120000)
  T.ok(result, "no response from " .. endpoint)
  T.ok(result.status == "ok", "request failed: " .. tostring(result.error))
  return result
end

T.test("live: quote-initial dialogue keeps its quotes and is not truncated", function()
  local result = ask(prompt.translate({
    source = "de",
    target = "en",
    before = T.de.before,
    after = T.de.after,
    selection = T.de.dialogue,
  }))
  T.ok(
    result.output:match('^%s*["\226\128\156\226\128\158\194\171]') ~= nil,
    "quotation marks were dropped: " .. result.output
  )
  T.ok(
    #result.output > 40,
    "looks truncated after the dialogue: " .. result.output
  )
end)

T.test("live: a gloss comes back as grammar, not as a translation", function()
  local result = ask(prompt.gloss({
    source = "de",
    target = "en",
    learner_level = "intermediate",
    before = T.de.before,
    after = T.de.after,
    selection = T.de.plain,
  }))
  local lowered = result.output:lower()
  T.ok(
    lowered:find("verb") or lowered:find("noun") or lowered:find("tense")
      or lowered:find("grammar") or lowered:find("case"),
    "expected a grammar breakdown, got: " .. result.output
  )
end)

T.test("live: a code replacement keeps its indentation", function()
  local result = ask(prompt.replace({
    instruction = "rename the variable x to total",
    filetype = "lua",
    selection = "    local x = 1\n    return x",
    context = "function f()\n    local x = 1\n    return x\nend",
    skills = {},
    agentic = false,
  }))
  local first = vim.split(result.output, "\n", { plain = true })[1]
  T.ok(first:match("^    "), "indentation lost: [" .. first .. "]")
  T.ok(result.output:find("total", 1, true), "the rename was not applied")
end)

T.test("live: a skilled replace fills both replacement and explanation", function()
  local result = ask(prompt.replace({
    instruction = "fix the grammar",
    filetype = "text",
    selection = "I going ride my bicicle",
    context = "I going ride my bicicle",
    skills = {
      "<skill name=\"grammar\">\nCorrect grammar and spelling. Also explain each"
        .. " fix: name the error, quote before and after, state the rule.\n</skill>",
    },
    agentic = false,
    explain = true,
  }))
  T.ok(
    result.output:lower():find("bicycle", 1, true),
    "the replacement field lost the correction: " .. result.output
  )
  T.ok(
    result.extra and #result.extra > 30,
    "the explanation field came back empty or trivial: " .. tostring(result.extra)
  )
end)
