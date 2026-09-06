--- The shared prompt-token scanner, the `/skill` reference resolver, the
--- one-line skill summaries, and the `<Tab>` completion callback -- everything
--- that decides what a `$provider` / `/skill` token is and whether it resolves.

local T = require("tests.helpers")
local prompt_tokens = require("gerty.prompt_tokens")
local skills = require("gerty.skills")
local gerty = require("gerty")

local ctx = {
  providers = { pi = true, claude = true },
  provider_names = { "claude", "pi" },
  skill_map = { grammar = "/x/grammar/SKILL.md", deslop = "/x/deslop/SKILL.md" },
}

T.test("a leading $alias is a known provider token spanning the sigil", function()
  local toks = prompt_tokens.scan("$claude fix this", ctx)
  T.eq(#toks, 1)
  T.eq(toks[1].kind, "provider")
  T.eq(toks[1].name, "claude")
  T.eq(toks[1].from, 0)
  T.eq(toks[1].to, 7, "0-indexed, exclusive -- covers '$claude'")
  T.ok(toks[1].known)
  T.eq(toks[1].resolved, "claude")
end)

T.test("$N resolves by position; out of range is unknown", function()
  T.eq(prompt_tokens.scan("$2 x", ctx)[1].resolved, "pi")
  local nine = prompt_tokens.scan("$9 x", ctx)[1]
  T.ok(not nine.known)
  T.eq(nine.resolved, nil)
end)

T.test("a non-leading $ is not a provider token", function()
  T.eq(#prompt_tokens.scan("fix the $foo variable", ctx), 0)
end)

T.test("/name is a skill token anywhere, known when discovered", function()
  local toks = prompt_tokens.scan("please /grammar and /nope this", ctx)
  T.eq(#toks, 2)
  T.eq(toks[1].name, "grammar")
  T.ok(toks[1].known)
  T.eq(toks[2].name, "nope")
  T.ok(not toks[2].known)
end)

T.test("a / not at a word start is left alone", function()
  T.eq(#prompt_tokens.scan("use and/or and read src/foo.lua", ctx), 0)
end)

T.test("trailing punctuation is not part of the skill name", function()
  local toks = prompt_tokens.scan("run /grammar, then stop", ctx)
  T.eq(toks[1].name, "grammar")
  T.ok(toks[1].known)
end)

T.test("tokens come back ordered by position", function()
  local toks = prompt_tokens.scan("$1 then /grammar then /deslop", ctx)
  T.eq(toks[1].name, "1")
  T.eq(toks[2].name, "grammar")
  T.eq(toks[3].name, "deslop")
  T.ok(toks[1].from < toks[2].from and toks[2].from < toks[3].from)
end)

T.test("scan offsets are byte-accurate after multibyte text", function()
  local toks = prompt_tokens.scan("über /grammar", ctx)
  -- "über " is 6 bytes (ü = 2); the '/' sits at byte index 6 (0-indexed)
  T.eq(toks[1].from, 6)
  T.eq(toks[1].to, 14)
end)

-- skills.resolve / skills.summary against real files ------------------------

local function write_skill(dir, name, body)
  vim.fn.mkdir(dir .. "/" .. name, "p")
  local f = assert(io.open(dir .. "/" .. name .. "/SKILL.md", "w"))
  f:write(body)
  f:close()
end

T.test("resolve injects known skills once and reports unknown ones", function()
  local dir = vim.fn.tempname()
  write_skill(dir, "alpha", "# alpha\n\nAlpha does a thing.\n")
  local map = skills.discover({ dir })

  local names, contents, unknown =
    skills.resolve("/alpha /alpha /missing go", map)
  T.eq(#names, 1, "deduped")
  T.eq(names[1], "alpha")
  T.ok(contents[1]:find("Alpha does a thing", 1, true))
  T.ok(contents[1]:find('<skill name="alpha">', 1, true))
  T.eq(#unknown, 1)
  T.eq(unknown[1], "missing")
end)

T.test("summary prefers a real heading, skips a name-echo heading", function()
  local dir = vim.fn.tempname()
  write_skill(dir, "grammar", "# grammar\n\nCheck and fix grammar and spelling.\n")
  write_skill(dir, "mentor", "# Explain like a patient teacher\n\nBody.\n")
  local map = skills.discover({ dir })

  T.eq(
    skills.summary(map.grammar, "grammar"),
    "Check and fix grammar and spelling.",
    "name-echo heading skipped, first prose line used"
  )
  T.eq(skills.summary(map.mentor, "mentor"), "Explain like a patient teacher")
end)

T.test("summary caps very long text", function()
  local dir = vim.fn.tempname()
  write_skill(dir, "long", "# long\n\n" .. string.rep("word ", 40) .. "\n")
  local map = skills.discover({ dir })
  local s = skills.summary(map.long, "long")
  T.ok(vim.fn.strdisplaywidth(s) <= 100, "capped")
  T.ok(s:sub(-3) == "…", "ellipsised") -- "…" is 3 bytes
end)

T.test("the summary cap counts display cells, not characters", function()
  -- a character-indexed cut leaves double-width text at ~198 cells, which
  -- matters here more than most: the language ops are the point of gerty
  local dir = vim.fn.tempname()
  write_skill(dir, "cjk", "# cjk\n\n" .. string.rep("日本語", 60) .. "\n")
  local map = skills.discover({ dir })
  local s = skills.summary(map.cjk, "cjk")
  T.ok(
    vim.fn.strdisplaywidth(s) <= 100,
    "wide characters overflowed the card: " .. vim.fn.strdisplaywidth(s)
  )
  T.ok(s:sub(-3) == "…", "ellipsised")
end)

T.test("a summary is re-read after its SKILL.md changes", function()
  local dir = vim.fn.tempname()
  write_skill(dir, "edited", "# edited\n\nFirst wording.\n")
  local map = skills.discover({ dir })
  T.eq(skills.summary(map.edited, "edited"), "First wording.")
  -- getftime has one-second resolution, so move the file's mtime explicitly
  -- rather than racing it
  write_skill(dir, "edited", "# edited\n\nSecond wording.\n")
  vim.fn.system({ "touch", "-t", "203001010000", map.edited })
  T.eq(
    skills.summary(map.edited, "edited"),
    "Second wording.",
    "the memo must not outlive the file it summarises"
  )
end)

-- <Tab> completion callback ------------------------------------------------

T.test("gerty_prompt_complete filters by the token prefix", function()
  local dir = vim.fn.tempname()
  write_skill(dir, "grammar", "# g\nx\n")
  write_skill(dir, "deslop", "# d\nx\n")
  gerty.setup({
    providers = { pi = { models = { "m" } }, claude = { models = { "m" } } },
    skills = { dir },
  })

  T.eq(
    vim.inspect(_G.gerty_prompt_complete("/d")),
    vim.inspect({ "/deslop" }),
    "prefix match on skills"
  )
  local dollar = _G.gerty_prompt_complete("$")
  T.ok(vim.tbl_contains(dollar, "$claude"))
  T.ok(vim.tbl_contains(dollar, "$1"))
  T.ok(vim.tbl_contains(dollar, "$2"))
  T.ok(not vim.tbl_contains(dollar, "/grammar"), "$ prefix excludes skills")

  local all = _G.gerty_prompt_complete("")
  T.ok(vim.tbl_contains(all, "/grammar") and vim.tbl_contains(all, "$pi"))
end)
