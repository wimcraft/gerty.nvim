--- `replace` is constrained: the model must only write the replacement text
--- to a temp file, never touch real files. `ask` is agentic: the model is
--- expected to edit real files with its own tools, so no output-file dance.
---
--- Every builder returns a transport-neutral `gerty.Prompt` (`{ system?,
--- user }`) rather than a CLI string or an OpenAI message array, so an op can
--- be routed to a CLI agent or an HTTP chat model at runtime without the
--- prompt shape becoming the wrong type. transport.lua does the conversion.
---
--- The code ops put everything in `user`, byte for byte what they sent
--- before there was a Prompt type. The language ops split the task
--- description into `system` and leave `user` as the text to work on, which
--- is what a chat model expects.
---
--- Each builder also names the JSON key it wants to be answered in
--- (`response_field`). transport.lua turns that into a decoding grammar for
--- an OpenAI-compatible endpoint and ignores it for a CLI, so an op declares
--- the shape of its answer once and gets it enforced wherever it can be.
---
--- **The field name is not cosmetic, and it belongs to the OP, not to the
--- provider.** The grammar only forces the shape -- the model is still free
--- to ramble *inside* the string, and with a vague key ("output",
--- "explanation") it does exactly that. A key that names the content
--- ("translation", "grammar_notes") commits it to an answer before it can
--- start narrating. Measured, not guessed. The flip side: the key can
--- override the system prompt outright -- running the gloss prompt through a
--- "translation" field returns a translation -- which is precisely why it is
--- set here, next to the prompt it belongs to, and not on a provider that has
--- no idea which op is calling it.

local M = {}

--- ISO codes read fine in config but badly in a prompt; a model given
--- "translate from de to en" is being asked to guess. Anything not listed
--- falls through as the raw code, which is still better than nothing.
--- @type table<string, string>
local LANGUAGE_NAMES = {
  ar = "Arabic",
  cs = "Czech",
  da = "Danish",
  de = "German",
  el = "Greek",
  en = "English",
  es = "Spanish",
  fi = "Finnish",
  fr = "French",
  he = "Hebrew",
  hu = "Hungarian",
  it = "Italian",
  ja = "Japanese",
  ko = "Korean",
  nl = "Dutch",
  no = "Norwegian",
  pl = "Polish",
  pt = "Portuguese",
  ro = "Romanian",
  ru = "Russian",
  sv = "Swedish",
  tr = "Turkish",
  uk = "Ukrainian",
  zh = "Chinese",
}

--- @param code string
--- @return string
function M.language_name(code)
  return LANGUAGE_NAMES[code] or LANGUAGE_NAMES[code:lower()] or code
end

--- `opts.agentic` false means the provider has no tools, so there is no file
--- for it to write the replacement into. It returns the replacement as its
--- answer instead, and `response_field` is what stops anything else coming
--- back with it. Same swap `explain` makes below, for the same reason:
--- telling a model to write to a path it cannot open does not make it
--- decline, it makes it claim it did.
---
--- `response_prose = false` matters. The leading-space sentinel every prose op
--- uses (see transport.lua) exists to keep position 0 from being a quotation
--- mark, and the trim that removes it again would take the first line's
--- INDENTATION with it -- these lines go straight back into a buffer at a
--- fixed range, so that indentation is the replacement's own and has to
--- survive.
---
--- `explain`, set only when a skill is active, opens an explanation channel.
--- The transports carry it differently:
---
---  * an **agentic** provider writes the code to the temp file with its own
---    tools and its stdout *reply* becomes the explanation. (An earlier
---    version asked it to append a delimiter + prose to the file it was told
---    to fill; models just wrote the file and stopped.)
---  * a **chat** provider gets a two-key grammar -- `{ replacement,
---    explanation }`, both required -- so constrained decoding forces the
---    explanation out. Trying to fit code + a delimiter + prose into the one
---    `replacement` string fought the "begin with the code" anchor and a
---    small model produced nothing after the code.
---
--- Either way gerty stays neutral on *how much* to explain -- that's the
--- skill's call. When `explain` is false the wording is byte-for-byte what it
--- has always been, so a plain `replace` is unperturbed (the local-model
--- phrasing here is measured, not casual).
---
--- @param opts { instruction: string, filetype: string, selection: string, context: string, tmp_file: string|nil, skills: string[], agentic: boolean|nil, explain: boolean|nil }
--- @return gerty.Prompt
function M.replace(opts)
  local agentic = opts.agentic ~= false
  local explain = opts.explain == true
  local parts = {
    "You are editing code inside a Neovim buffer.",
    "Rewrite ONLY the <selection> below according to <instruction>.",
    explain and (
      agentic
          and string.format(
            "Write the corrected code, and nothing else, to the file at %s -- "
              .. "no markdown code fences, and modify no other file. THEN make "
              .. "your reply an explanation of the changes: what you changed and "
              .. "why, at whatever depth <instruction> or a skill asks for. Do "
              .. "not repeat the corrected text in your reply. If you changed "
              .. "nothing, reply with nothing.",
            opts.tmp_file
          )
        or "Put the corrected code -- no markdown code fences, the selection's "
          .. "own indentation preserved on every line -- in the `replacement` "
          .. "field. Put an explanation of the changes in the `explanation` "
          .. "field: what you changed and why, at whatever depth <instruction> "
          .. "or a skill asks for. If nothing needed changing, return the text "
          .. "unchanged in `replacement` and say so in `explanation`."
    ) or (
      agentic
          and string.format(
            "Write the replacement code, and nothing else, to the file at %s. "
              .. "Do not add commentary, explanations, or markdown code fences. "
              .. "Do not modify any file other than that one.",
            opts.tmp_file
          )
        or "Return the replacement code and nothing else -- no commentary, no "
          .. "explanation, no markdown code fences. Reproduce the selection's "
          .. "own indentation on every line, including the first."
    ),
  }

  if #opts.skills > 0 then
    vim.list_extend(parts, opts.skills)
  end

  table.insert(parts, string.format("<filetype>%s</filetype>", opts.filetype))
  table.insert(
    parts,
    string.format("<context>\n%s\n</context>", opts.context)
  )
  table.insert(
    parts,
    string.format("<selection>\n%s\n</selection>", opts.selection)
  )
  table.insert(
    parts,
    string.format("<instruction>\n%s\n</instruction>", opts.instruction)
  )

  -- the same closing anchor `explain` uses, and for the same measured reason:
  -- a small model opens by restating the task unless the last thing it reads
  -- says not to. An agentic CLI does not have the habit, so it is left alone.
  if not agentic then
    table.insert(
      parts,
      explain
          and "Fill `replacement` with the corrected code itself, no preamble."
        or "Begin your reply with the replacement code itself."
    )
  end

  return {
    user = table.concat(parts, "\n\n"),
    response_field = not agentic and "replacement" or nil,
    response_field_extra = (not agentic and explain) and "explanation" or nil,
    response_prose = false,
  }
end

--- `explain` is the read-only counterpart of `replace`: same selection, but
--- the answer is prose on stdout instead of code in a file. The model gets
--- the repo root and the selection's `file:line` anchor so it can go read
--- callers, definitions and tests for itself rather than guessing from the
--- snippet alone.
---
--- `opts.agentic` false means the provider has no tools. Telling a model to
--- "read whatever you need from the repository" when it cannot read anything
--- does not make it decline -- it makes it invent plausible file contents and
--- cite paths that were never opened. So the instruction is swapped, not just
--- softened, and the model is told to say when the snippet is not enough.
---
--- @param opts { instruction: string, cwd: string, file: string, filetype: string, start_line: number, end_line: number, selection: string, skills: string[], agentic: boolean|nil }
--- @return gerty.Prompt
function M.explain(opts)
  local agentic = opts.agentic ~= false
  local parts = {
    agentic
        and string.format(
          "You are a code analyst working in the repository at %s. "
            .. "The <selection> below comes from %s, lines %d-%d.",
          opts.cwd,
          opts.file,
          opts.start_line,
          opts.end_line
        )
      or string.format(
        "You are explaining a selection the user has open in their editor. "
          .. "It comes from %s, lines %d-%d.",
        opts.file,
        opts.start_line,
        opts.end_line
      ),
    agentic
        and "Read whatever you need from the repository to answer accurately -- "
          .. "the definitions this code depends on, its callers, its tests, "
          .. "related configuration. Do not answer from the snippet alone if "
          .. "the repository can tell you more."
      or "You cannot open any other file. Answer from the selection and your "
        .. "own knowledge alone, and say plainly when something cannot be "
        .. "determined from the selection -- never guess at the contents of "
        .. "files you have not seen.",
    "This is a read-only task. Do not create, modify, or delete any file.",
    agentic
        and "Answer in Markdown, directly to stdout. Be concise and concrete: "
          .. "reference real symbols and real paths from the repository rather "
          .. "than describing the code in general terms. Do not wrap the whole "
          .. "answer in a code fence."
      or "Answer in Markdown, directly to stdout. Be concise and concrete. "
        .. "Do not wrap the whole answer in a code fence.",
  }

  if #opts.skills > 0 then
    vim.list_extend(parts, opts.skills)
  end

  table.insert(parts, string.format("<filetype>%s</filetype>", opts.filetype))
  table.insert(
    parts,
    string.format("<selection>\n%s\n</selection>", opts.selection)
  )
  table.insert(
    parts,
    string.format("<instruction>\n%s\n</instruction>", opts.instruction)
  )

  -- Small reasoning-tuned models open by restating the task ("The user wants
  -- to know...", "The selection is in German...") and only then answer. The
  -- same sentence placed up in the preamble does nothing -- it has to be the
  -- LAST thing before generation to beat the habit. Measured on gemma-4-e4b:
  -- 0/6 clean without it, 6/6 with, across both prose and code. Agentic CLI
  -- providers do not have the problem, so their prompt is left untouched.
  if not agentic then
    table.insert(
      parts,
      "Begin your reply with the explanation itself. Do not restate the "
        .. "question, the selection, or what you are about to do."
    )
  end

  return { user = table.concat(parts, "\n\n"), response_field = "answer" }
end

--- @param opts { instruction: string, cwd: string, file: string, skills: string[] }
--- @return gerty.Prompt
function M.ask(opts)
  local parts = {
    string.format(
      "You are a coding agent working in %s. You may read and edit any files "
        .. "needed to complete the task. The file currently open in the editor "
        .. "is %s.",
      opts.cwd,
      opts.file
    ),
  }

  if #opts.skills > 0 then
    vim.list_extend(parts, opts.skills)
  end

  table.insert(
    parts,
    string.format("<instruction>\n%s\n</instruction>", opts.instruction)
  )

  return { user = table.concat(parts, "\n\n") }
end

--- The language ops share one user message: surrounding text marked as
--- context the model must *not* act on, then the selection it must. Keeping
--- the two visibly separated is the whole reason `translate` doesn't just get
--- handed a paragraph -- it should resolve a pronoun from the sentence before
--- without translating that sentence too.
---
--- @param opts { before: string, after: string, selection: string }
--- @return string
--- The `tail` also restates the OUTPUT LANGUAGE, even though the system prompt
--- already names it. That is not redundancy for its own sake: one report had a
--- long line come back in Bengali, and a language flip is exactly the failure a
--- closing anchor is placed to catch -- the system prompt is many hundreds of
--- tokens away by the time generation starts, and everything in this file so
--- far says recency wins. Could not be reproduced in 40+ samples, so this is a
--- cheap guard against a rare fault rather than a verified fix.
---
--- `tail` is a closing instruction, and it has to be the LAST thing in the
--- message to do its job. Without one, a small model given several lines of
--- context stops after the first sentence of the selection: a line reading
--- „Das bin ich!" Die Eingangstür hat sich geöffnet und Victoria betritt das
--- Geschäft. came back as just "That's me!" -- 0/6 with a long context block,
--- 6/6 once this line is appended, and 5/5 even without it when the context was
--- short. So it is context volume, not the quotation marks, that makes the
--- model lose the end of the selection; the banner above is too far away by
--- then to still be doing any work.
---
--- @param opts { before: string, after: string, selection: string }
--- @param tail string|nil
--- @return string
local function language_user_text(opts, tail)
  local parts = {
    "Below is surrounding text for CONTEXT ONLY. Do not translate or explain it;",
    "use it solely to resolve ambiguity (pronouns, gender, register, idioms).",
    "",
    "----- CONTEXT BEFORE -----",
    opts.before,
    "----- CONTEXT AFTER -----",
    opts.after,
    "",
    "===== TEXT TO PROCESS (act on ONLY this) =====",
    opts.selection,
  }
  if tail then
    table.insert(parts, "")
    table.insert(parts, tail)
  end
  return table.concat(parts, "\n")
end

--- @param system string
--- @param skills string[]
--- @return string
local function with_skills(system, skills)
  if not skills or #skills == 0 then
    return system
  end
  return table.concat({ system, table.concat(skills, "\n\n") }, "\n\n")
end

--- @param opts { source: string, target: string, before: string, after: string, selection: string, skills: string[]|nil }
--- @return gerty.Prompt
function M.translate(opts)
  local system = string.format(
    "Translate the marked %s text to %s. Output only the translation, "
      .. "no commentary.",
    M.language_name(opts.source),
    M.language_name(opts.target)
  )
  return {
    system = with_skills(system, opts.skills),
    user = language_user_text(
      opts,
      string.format(
        "Translate the whole of that text, every sentence of it, from the "
          .. "first word to the last. Write the translation in %s.",
        M.language_name(opts.target)
      )
    ),
    response_field = "translation",
  }
end

--- Two behaviours in one op, matching `explain`'s empty-submit convention: no
--- instruction means the default grammar/vocabulary breakdown, an
--- instruction means do that instead against the same selection.
---
--- @param opts { source: string, target: string, learner_level: string, instruction: string|nil, before: string, after: string, selection: string, skills: string[]|nil }
--- @return gerty.Prompt
function M.gloss(opts)
  local instruction = opts.instruction and vim.trim(opts.instruction) or ""
  local system
  if instruction == "" then
    system = string.format(
      "Explain the grammar and vocabulary of the marked %s text for a %s "
        .. "learner, answering in %s. Be concise. Note anything ambiguous "
        .. "or idiomatic.",
      M.language_name(opts.source),
      opts.learner_level,
      M.language_name(opts.target)
    )
  else
    system = string.format(
      "%s\n\nThe marked text is in %s. Answer in %s.",
      instruction,
      M.language_name(opts.source),
      M.language_name(opts.target)
    )
  end
  return {
    system = with_skills(system, opts.skills),
    user = language_user_text(
      opts,
      string.format(
        "Cover the whole of that text, every sentence of it, from the first "
          .. "word to the last. Write your answer in %s.",
        M.language_name(opts.target)
      )
    ),
    -- "grammar_notes", not "answer": a field named after what the op actually
    -- produces is what commits the model to producing it. See the header.
    response_field = "grammar_notes",
  }
end

return M
