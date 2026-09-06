# Changelog

Notable changes per release. Dates are ISO. This project is pre-1.0: minor versions may break things, and breaking changes are called out explicitly.

## [0.1.0] — 2026-09-07

### Breaking

- Skills are referenced with `/name` instead of `#name`, with no `#` fallback. Rename your references; the `SKILL.md` files themselves are unchanged. The `/` must start the instruction or follow whitespace, so `and/or` and `src/foo.lua` are no longer mistaken for references — which is the reason for the change.

### Added

- `$N` numeric provider shorthand: `$1` routes to the first provider in the reference card's (sorted) order, `$2` the second. An out-of-range `$N` is left in the instruction like any other unrecognised token.
- Live token colouring at the built-in prompt: `$provider` and `/skill` tokens are highlighted as you type, in different groups depending on whether they resolve. Restyle with `:hi GertyPromptToken` / `:hi GertyPromptTokenUnknown`, or disable with `prompt_highlight = false`.
- `<Tab>` completion of `$provider` and `/skill` tokens at the built-in prompt. Disable with `prompt_completion = false`.
- `config.prompt_keys`, opt-in and empty by default: bind a keypress at the prompt to inserting a leading `$alias`. Values are a provider alias or a 1-based index into the sorted alias list.
- The reference card shows a one-line summary for each skill, taken from its `SKILL.md`, and now always shows the skills section — with a line explaining how to configure `skills` when none are discovered.
- A `/name` that matches no discovered skill produces a warning after submit instead of silently doing nothing. The token itself is still left in the instruction, matching how `$notaprovider` behaves.
- Explanation channel for skilled `replace`: when a skill is referenced, the model is asked to explain its edit on a channel separate from the replacement — an agentic CLI's stdout reply, or a second required key in the chat decoding grammar. The explanation opens in a float that does not take focus, the changed lines get the persistent `▎` sign, and the edit is recorded in `gerty.history()` so the note can be re-opened from cache without another request. Disable with `replace_explain = false`.

### Fixed

- `config.prompt_keys` now rejects an index past the end of the provider list at `setup()`, instead of installing a key that silently does nothing.
- Skill summaries are truncated by display width rather than character count, so double-width scripts no longer overflow the reference card.

## [0.0.1] — 2026-09-06

First tagged version. Work in progress; see the README for what is deliberately not included.
