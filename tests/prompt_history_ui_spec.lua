local T = require("tests.helpers")
local gerty = require("gerty")
local history = require("gerty.prompt_history")

local function with_history(fn)
  local dir = vim.fn.tempname()
  local previous_path = history._set_path_for_test(dir .. "/prompt-history.json")
  local ok, err = pcall(fn)
  history._set_path_for_test(previous_path)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

local function setup()
  gerty.setup({
    providers = {
      first = { type = "lmstudio", models = { "first-model" } },
      second = { type = "lmstudio", models = { "second-model" } },
    },
  })
end

local function with_input(value, fn)
  local original = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    on_confirm(value)
  end
  local ok, err = pcall(fn)
  vim.ui.input = original
  if not ok then
    error(err, 0)
  end
end

T.test("interactive replace stores the exact routed instruction before parsing", function()
  with_history(function()
    setup()
    local mock = T.mock_jobs()
    mock.reply = { status = "cancelled" }
    T.buffer_with_selection({ "selected" }, 1, 1)

    with_input("$2 translate to German", gerty.replace)
    T.wait_for(function() return mock.last ~= nil end)

    T.eq(history.list("replace")[1], "$2 translate to German")
    local request = vim.json.decode(mock.last.stdin)
    T.eq(request.model, "second-model", "$2 must keep selecting the second provider")
    T.unmock_jobs(mock)
  end)
end)

T.test("interactive explain stores questions but not its empty-submit default", function()
  with_history(function()
    setup()
    local mock = T.mock_jobs()
    mock.reply = { status = "cancelled" }

    T.buffer_with_selection({ "selected" }, 1, 1)
    with_input("why is this branch needed?", gerty.explain)
    T.wait_for(function() return mock.last ~= nil end)
    T.eq(history.list("explain")[1], "why is this branch needed?")

    T.buffer_with_selection({ "other selection" }, 1, 1)
    with_input("", gerty.explain)
    T.wait_for(function() return mock.calls == 2 end)
    T.eq(#history.list("explain"), 1, "the generated default is not user history")
    T.unmock_jobs(mock)
  end)
end)

T.test("direct instructions are not prompt history", function()
  with_history(function()
    setup()
    local mock = T.mock_jobs()
    mock.reply = { status = "cancelled" }
    T.buffer_with_selection({ "selected" }, 1, 1)

    gerty.replace({ instruction = "$2 direct call" })
    T.wait_for(function() return mock.last ~= nil end)
    T.eq(#history.list("replace"), 0)
    T.unmock_jobs(mock)
  end)
end)

T.test("the history picker exposes operation-specific choices without dispatching", function()
  with_history(function()
    setup()
    history.record("replace", "$2 translate to German")
    history.record("explain", "why is this branch needed?")
    local mock = T.mock_jobs()
    local original_select = vim.ui.select
    local original_input = vim.ui.input
    local selected

    vim.ui.select = function(items, opts, on_choice)
      T.eq(opts.prompt, "gerty: replace history")
      T.eq(#items, 1)
      T.eq(items[1], "$2 translate to German")
      selected = items[1]
      on_choice(items[1])
    end
    vim.ui.input = function(_, on_confirm)
      local map = vim.fn.maparg("<C-r>", "c", false, true)
      T.eq(type(map.callback), "function", "history map was not installed")
      map.callback()
      T.eq(mock.calls, 0, "picking history must not dispatch a request")
      on_confirm(nil)
    end

    T.buffer_with_selection({ "selected" }, 1, 1)
    gerty.replace()
    vim.ui.input = original_input
    vim.ui.select = original_select
    T.eq(selected, "$2 translate to German")
    T.eq(vim.fn.maparg("<C-r>", "c"), "", "history map escaped the prompt")
    T.unmock_jobs(mock)
  end)
end)

T.test("history map restores a shadowed command-line mapping", function()
  with_history(function()
    setup()
    vim.keymap.set("c", "<C-r>", "<C-r>", { noremap = true })
    local before = vim.fn.maparg("<C-r>", "c", false, true)
    local original = vim.ui.input
    local seen = {}
    vim.ui.input = function(_, on_confirm)
      seen.replace = vim.fn.maparg("<C-r>", "c", false, true).desc
      on_confirm(nil)
    end

    T.buffer_with_selection({ "selected" }, 1, 1)
    gerty.replace()
    vim.ui.input = original
    local after = vim.fn.maparg("<C-r>", "c", false, true)
    vim.keymap.del("c", "<C-r>")

    T.eq(seen.replace, "gerty: recall replace prompt")
    T.eq(after.rhs, before.rhs, "shadowed command-line mapping was not restored")
  end)
end)

T.test("a cancelled prompt-history picker leaves the prompt inert", function()
  with_history(function()
    setup()
    history.record("replace", "earlier instruction")
    local mock = T.mock_jobs()
    local original_select = vim.ui.select
    local original_input = vim.ui.input

    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end
    vim.ui.input = function(_, on_confirm)
      vim.fn.maparg("<C-r>", "c", false, true).callback()
      T.eq(mock.calls, 0, "cancelling the picker must not dispatch")
      on_confirm(nil)
    end

    T.buffer_with_selection({ "selected" }, 1, 1)
    gerty.replace()
    vim.ui.input = original_input
    vim.ui.select = original_select
    T.eq(vim.fn.maparg("<C-r>", "c"), "", "history map escaped the prompt")
    T.unmock_jobs(mock)
  end)
end)

T.test("a custom input buffer replaces its register action with prompt history", function()
  with_history(function()
    setup()
    history.record("replace", "$2 translate to German")
    local mock = T.mock_jobs()
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "existing input" })
    vim.keymap.set("i", "<C-r>", "<C-r>", { buffer = input_buf, noremap = true })
    local before = vim.api.nvim_buf_call(input_buf, function()
      return vim.fn.maparg("<C-r>", "i", false, true)
    end)
    local original_select = vim.ui.select
    local original_input = vim.ui.input
    local on_confirm

    vim.ui.input = function(_, callback)
      vim.api.nvim_set_current_buf(input_buf)
      on_confirm = callback
    end
    vim.ui.select = function(items, opts, on_choice)
      T.eq(opts.prompt, "gerty: replace history")
      T.eq(items[1], "$2 translate to German")
      on_choice(items[1])
    end

    T.buffer_with_selection({ "selected" }, 1, 1)
    gerty.replace()
    T.wait_for(function()
      return vim.api.nvim_buf_call(input_buf, function()
        return vim.fn.maparg("<C-r>", "i", false, true).desc
          == "gerty: recall replace prompt"
      end)
    end)

    vim.api.nvim_buf_call(input_buf, function()
      vim.fn.maparg("<C-r>", "i", false, true).callback()
    end)
    T.eq(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1], "$2 translate to German")
    T.eq(mock.calls, 0, "selection must only edit the custom input")

    on_confirm(nil)
    local after = vim.api.nvim_buf_call(input_buf, function()
      return vim.fn.maparg("<C-r>", "i", false, true)
    end)
    vim.keymap.del("i", "<C-r>", { buffer = input_buf })
    vim.ui.input = original_input
    vim.ui.select = original_select
    T.eq(after.rhs, before.rhs, "custom input register mapping was not restored")
    T.unmock_jobs(mock)
  end)
end)
