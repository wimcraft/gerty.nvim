--- Test runner. Usage, from anywhere:
---
---     nvim -l tests/run.lua
---     GERTY_TEST_LIVE=1 nvim -l tests/run.lua   -- also hit a real local model
---
--- Exits non-zero if anything failed, so CI can use it directly.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. package.path

local T = require("tests.helpers")

local specs = {
  "config",
  "prompt_tokens",
  "transport",
  "routing",
  "replace",
  "lifecycle",
  "live",
}

local started = vim.uv.hrtime()
for _, name in ipairs(specs) do
  io.write("\n" .. name .. "\n")
  local ok, err = pcall(require, "tests." .. name .. "_spec")
  if not ok then
    table.insert(T.failures, { name = name .. " (failed to load)", err = tostring(err) })
    io.write("  FAIL could not load: " .. tostring(err) .. "\n")
  end
end

local elapsed = (vim.uv.hrtime() - started) / 1e9
io.write(string.format("\n%d passed, %d failed  (%.1fs)\n", T.passed, #T.failures, elapsed))
for _, failure in ipairs(T.failures) do
  io.write("  " .. failure.name .. ": " .. failure.err .. "\n")
end

os.exit(#T.failures == 0 and 0 or 1)
