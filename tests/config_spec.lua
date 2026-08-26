--- Configuration resolution and validation. Every assertion in config.lua
--- exists so a typo fails at setup() rather than three operations later, so
--- these tests check the MESSAGE as well as the failure.

local T = require("tests.helpers")
local config = require("gerty.config")
local gerty = require("gerty")

T.test("zero config yields a usable pi provider", function()
  gerty.setup({})
  T.eq(gerty.get_provider(), "pi")
end)

T.test("type defaults to the alias", function()
  local cfg = config.resolve({ providers = { pi = {}, claude = {} } })
  T.eq(cfg.providers.pi.transport, "cli")
  T.eq(cfg.providers.claude.model, "claude-sonnet-5", "claude default model")
end)

T.test("an alias that is not a type needs one", function()
  T.raises(function()
    config.resolve({ providers = { foo = {} } })
  end, "known types")
end)

T.test("model defaults to the first listed", function()
  local cfg = config.resolve({ providers = { pi = { models = { "a", "b" } } } })
  T.eq(cfg.providers.pi.model, "a")
end)

T.test("an explicit model outside the list is still offered", function()
  local cfg = config.resolve({
    providers = { claude = { model = "claude-opus-5", models = { "claude-sonnet-5" } } },
  })
  T.eq(#cfg.providers.claude.models, 2)
  T.eq(cfg.providers.claude.models[1].id, "claude-opus-5")
end)

T.test("string and table model entries both work", function()
  local cfg = config.resolve({
    providers = { pi = { models = { "a", { id = "b", name = "Bee" } } } },
  })
  T.eq(cfg.providers.pi.models[1].name, "a", "name defaults to id")
  T.eq(cfg.providers.pi.models[2].name, "Bee")
end)

T.test("a malformed model entry names its index", function()
  T.raises(function()
    config.resolve({ providers = { pi = { models = { 42 } } } })
  end, "models[1]")
end)

T.test("billing is inherited and overridable per model", function()
  local cfg = config.resolve({
    providers = {
      pi = { billing = "Sub", models = { "a", { id = "b", billing = "Metered" } } },
    },
  })
  T.eq(config.billing_for(cfg.providers.pi, "a"), "Sub")
  T.eq(config.billing_for(cfg.providers.pi, "b"), "Metered")
end)

T.test("default falls back to the first alias alphabetically", function()
  local cfg = config.resolve({
    providers = { pi = {}, claude = {}, ["local"] = { type = "lmstudio" } },
  })
  T.eq(cfg.default, "claude")
end)

T.test("an unknown default lists the configured aliases", function()
  T.raises(function()
    config.resolve({ providers = { pi = {} }, default = "smart" })
  end, "is not one of: pi")
end)

T.test("an op_defaults typo lists the known operations", function()
  T.raises(function()
    config.resolve({ providers = { pi = {} }, op_defaults = { translte = "pi" } })
  end, "known operations")
end)

T.test("an op_defaults value must name a configured provider", function()
  T.raises(function()
    config.resolve({ providers = { pi = {} }, op_defaults = { translate = "nope" } })
  end, "op_defaults.translate")
end)

T.test("lmstudio and ollama presets fill in their endpoints", function()
  local cfg = config.resolve({
    providers = {
      lm = { type = "lmstudio" },
      ol = { type = "ollama" },
    },
  })
  T.eq(cfg.providers.lm.endpoint, "http://localhost:1234/v1/chat/completions")
  T.eq(cfg.providers.ol.endpoint, "http://localhost:11434/v1/chat/completions")
  T.eq(cfg.providers.lm.temperature, 0.2)
  T.eq(cfg.providers.lm.capabilities.agentic, false)
end)

T.test("a preset endpoint can be overridden", function()
  local cfg = config.resolve({
    providers = { lm = { type = "lmstudio", endpoint = "http://elsewhere/v1/chat/completions" } },
  })
  T.eq(cfg.providers.lm.endpoint, "http://elsewhere/v1/chat/completions")
end)

T.test("a chat provider with no endpoint is rejected", function()
  T.raises(function()
    config.resolve({ providers = { x = { type = "openai_compat" } } })
  end, "needs an `endpoint`")
end)

T.test("a language preset needs both ends", function()
  T.raises(function()
    config.resolve({ providers = { pi = {} }, language_presets = { { source = "de" } } })
  end, "source and a target")
end)

T.test("list defaults are replaced, not merged", function()
  local cfg = config.resolve({ providers = { pi = {} }, dictionary = { command = { "trans" } } })
  T.eq(#cfg.dictionary.command, 1, "dictionary.command length")
  T.eq(cfg.dictionary.command[1], "trans")
end)

T.test("a custom type table is accepted", function()
  local cfg = config.resolve({
    providers = {
      mine = {
        type = {
          name = "mine",
          transport = "cli",
          capabilities = { agentic = true },
          build_command = function() return { "mine" } end,
        },
        models = { "m" },
      },
    },
  })
  T.eq(cfg.providers.mine.name, "mine")
  T.eq(cfg.providers.mine.model, "m")
end)

T.test("a type table without build_command is rejected", function()
  T.raises(function()
    config.resolve({ providers = { mine = { type = { name = "mine" } } } })
  end, "build_command")
end)

T.test("the module reports a semantic version", function()
  local version = require("gerty").version
  T.ok(type(version) == "string", "version must be a string")
  T.ok(
    version:match("^%d+%.%d+%.%d+$") ~= nil,
    "expected MAJOR.MINOR.PATCH, got " .. tostring(version)
  )
end)
