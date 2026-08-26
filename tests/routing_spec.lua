--- Which provider serves a call: $alias, op_defaults, the global default, and
--- the guard that stops `ask` reaching a provider with no tools.

local T = require("tests.helpers")
local gerty = require("gerty")

local function setup()
  gerty.setup({
    providers = {
      pi = { billing = "Sub", models = { "pi-model", "pi-other" } },
      claude = { billing = "Sub", models = { "claude-sonnet-5", "claude-opus-5" } },
      ["local"] = { type = "lmstudio", billing = "free", models = { "local-a", "local-b" } },
    },
    default = "pi",
    op_defaults = { translate = "local", gloss = "local" },
  })
end

T.test("op_defaults override the global default", function()
  setup()
  T.eq(gerty.get_provider(), "pi")
  T.eq(gerty.get_provider("translate"), "local")
  T.eq(gerty.get_provider("gloss"), "local")
  T.eq(gerty.get_provider("replace"), "pi")
end)

T.test("$alias routes one call and is stripped from the prompt", function()
  setup()
  local mock = T.mock_jobs()
  gerty.ask({ instruction = "$claude do a thing" })
  T.eq(mock.last.cmd[1], "claude")
  local sent = mock.last.cmd[#mock.last.cmd]
  T.ok(not sent:find("$claude", 1, true), "the token must not reach the model")
  T.ok(sent:find("do a thing", 1, true))
  T.unmock_jobs(mock)
end)

T.test("an unknown $token is left in the prompt", function()
  setup()
  local mock = T.mock_jobs()
  gerty.ask({ instruction = "$notaprovider do a thing" })
  T.eq(mock.last.cmd[1], "pi", "falls through to the default")
  T.ok(
    mock.last.cmd[#mock.last.cmd]:find("$notaprovider", 1, true),
    "eating part of someone's prompt is worse than ignoring a typo"
  )
  T.unmock_jobs(mock)
end)

T.test("ask refuses a chat-only provider before anything is sent", function()
  setup()
  local mock = T.mock_jobs()
  T.raises(function()
    gerty.ask({ instruction = "$local rewrite everything" })
  end, "chat-only")
  T.eq(mock.calls, 0, "nothing may be spawned for a request that cannot work")
  T.unmock_jobs(mock)
end)

T.test("every other op adapts to a chat-only provider instead of refusing", function()
  setup()
  local mock = T.mock_jobs()
  T.buffer_with_selection({ "line one", "line two" }, 1, 2)
  gerty.explain({ instruction = "$local what is this" })
  T.eq(mock.last.cmd[1], "curl", "explain runs on the chat endpoint")
  T.unmock_jobs(mock)
end)

T.test("a per-call provider beats the op default", function()
  setup()
  local mock = T.mock_jobs()
  T.buffer_with_selection({ "Hallo Welt", "Zweite Zeile" }, 1, 2)
  gerty.translate({ provider = "claude" })
  T.eq(mock.last.cmd[1], "claude")
  T.unmock_jobs(mock)
end)

T.test("translate routes to its op_default and carries the schema", function()
  setup()
  local mock = T.mock_jobs()
  T.buffer_with_selection({ "Hallo Welt", "Zweite Zeile" }, 1, 2)
  gerty.translate({})
  T.eq(mock.last.cmd[1], "curl")
  local schema = vim.json.decode(mock.last.stdin).response_format.json_schema.schema
  T.ok(schema.properties.translation, "the schema must survive the routing")
  T.unmock_jobs(mock)
end)

T.test("select_model offers one flat list across every provider", function()
  setup()
  local shown
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    shown = {}
    for _, item in ipairs(items) do
      table.insert(shown, opts.format_item(item))
    end
    on_choice(items[2]) -- claude-opus-5; the list is sorted by alias
  end
  T.capture_notify(function()
    gerty.select_model()
  end)
  vim.ui.select = original

  T.eq(#shown, 6, "6 models across 3 providers")
  T.ok(shown[1]:find("claude:", 1, true), "labelled by provider")
  T.ok(shown[1]:find("[Sub]", 1, true), "billing shown")
  T.eq(gerty.get_provider(), "claude", "picking a model switches the default provider")
  T.eq(gerty.get_provider("translate"), "local", "op_defaults must not be dragged along")
end)

T.test("the picked model is what later requests use", function()
  setup()
  local original = vim.ui.select
  vim.ui.select = function(items, _, on_choice)
    on_choice(items[2])
  end
  T.capture_notify(function()
    gerty.select_model()
  end)
  vim.ui.select = original

  local mock = T.mock_jobs()
  gerty.ask({ instruction = "x" })
  T.ok(vim.tbl_contains(mock.last.cmd, "claude-opus-5"))
  T.unmock_jobs(mock)
end)

T.test("set_provider changes the session default only", function()
  setup()
  T.capture_notify(function()
    gerty.set_provider("claude")
  end)
  T.eq(gerty.get_provider(), "claude")
  T.eq(gerty.get_provider("translate"), "local")
end)

T.test("an unknown provider name is rejected", function()
  setup()
  T.raises(function()
    gerty.set_provider("nope")
  end, "configured providers")
end)
