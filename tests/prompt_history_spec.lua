local T = require("tests.helpers")
local history = require("gerty.prompt_history")

local function with_store(fn)
  local dir = vim.fn.tempname()
  local path = dir .. "/prompt-history.json"
  local previous_path = history._set_path_for_test(path)
  local ok, err = pcall(fn, path)
  history._set_path_for_test(previous_path)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end


T.test("prompt history reloads its persisted replace and explain lists", function()
  with_store(function(path)
    history.record("replace", "$2 translate to German")
    history.record("explain", "why does this branch exist?")
    history._set_path_for_test(path)

    T.eq(history.list("replace")[1], "$2 translate to German")
    T.eq(history.list("explain")[1], "why does this branch exist?")
  end)
end)

T.test("prompt history promotes duplicates without crossing operations", function()
  with_store(function()
    history.record("replace", "first")
    history.record("replace", "second")
    history.record("replace", "first")
    history.record("explain", "first")

    local replace = history.list("replace")
    T.eq(#replace, 2)
    T.eq(replace[1], "first")
    T.eq(replace[2], "second")
    T.eq(#history.list("explain"), 1)
  end)
end)

T.test("prompt history ignores empty instructions", function()
  with_store(function()
    history.record("replace", "  \t")
    T.eq(#history.list("replace"), 0)
  end)
end)

T.test("prompt history caps each operation independently", function()
  with_store(function()
    for i = 1, history.MAX_ENTRIES + 1 do
      history.record("replace", "instruction " .. i)
    end

    local replace = history.list("replace")
    T.eq(#replace, history.MAX_ENTRIES)
    T.eq(replace[1], "instruction " .. (history.MAX_ENTRIES + 1))
    T.eq(replace[#replace], "instruction 2")
  end)
end)

T.test("prompt history recovers from malformed storage", function()
  with_store(function(path)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "this is not JSON" }, path)
    history._set_path_for_test(path)

    T.eq(#history.list("replace"), 0)
    history.record("replace", "recovered")
    history._set_path_for_test(path)
    T.eq(history.list("replace")[1], "recovered")
  end)
end)
