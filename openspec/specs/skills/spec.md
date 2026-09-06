# skills Specification

## Purpose

Reusable prompt fragments, referenced inline as `/name`. A skill is a
`SKILL.md` file in a configured directory; typing its name anywhere in a prompt
injects its contents as extra context.

## Requirements

### Requirement: Skill Discovery

The system SHALL scan the configured directories at `setup()` for
`<name>/SKILL.md`, taking the containing directory's name as the skill's name.
Paths SHALL be expanded, so `~`-relative directories work.

#### Scenario: Discovering skills

- **WHEN** a configured directory contains `mentor/SKILL.md` and `version-bump/SKILL.md`
- **THEN** the skills `mentor` and `version-bump` become referenceable

#### Scenario: Rescanning without a restart

- **WHEN** a new skill directory is added and `refresh_skills()` is called
- **THEN** the new skill becomes referenceable immediately

### Requirement: Inline Skill References

The system SHALL inject the contents of every referenced skill into the
request, wrapped and labelled with the skill's name. A reference SHALL be
honoured anywhere in the instruction, provided the `/` starts the instruction
or follows whitespace.

#### Scenario: Referencing a skill

- **WHEN** the user types `/refactor extract this into a helper function`
- **THEN** that skill's contents accompany the request

#### Scenario: A slash inside a word is not a reference

- **WHEN** the instruction contains `and/or` or a path like `src/foo.lua`
- **THEN** no skill lookup is attempted for `or` or `foo.lua`

#### Scenario: Repeated reference

- **WHEN** the same skill is referenced twice in one instruction
- **THEN** its contents are injected once

#### Scenario: Unknown skill

- **WHEN** a `/name` does not match a discovered skill
- **THEN** no injection occurs, the text is left in the instruction, and the
  user is notified after submitting that the token resolved to nothing

### Requirement: Skill Visibility

The system SHALL list the available skills on the inline reference card, and
SHALL name the skills in use in the status text of a running request.

#### Scenario: Skills on the reference card

- **WHEN** a prompt opens with skills discovered
- **THEN** each is listed as `/name` followed by a one-line summary taken from
  its `SKILL.md` (its first heading, or first line of prose), truncated by
  display width so double-width scripts do not overflow the card

#### Scenario: No skills discovered

- **WHEN** a prompt opens and no skill directory is configured or found
- **THEN** the card still shows the skills section, with a line explaining how
  to point `skills` at a directory — rather than omitting it silently

#### Scenario: Skills named during a request

- **WHEN** a request runs with skills referenced
- **THEN** their names appear in the status text alongside the operation

### Requirement: Prompt Token Feedback

At Neovim's built-in prompt the system SHALL colour `/skill` (and leading
`$provider`) tokens as they are typed, distinguishing a token that resolves
from one that does not, and SHALL offer `<Tab>` completion of both. Both
behaviours SHALL be individually disableable and SHALL degrade to nothing on a
custom `vim.ui.input` without error.

#### Scenario: A resolving token and a typo look different

- **WHEN** the instruction contains `/grammar` (a discovered skill) and `/grammr` (not)
- **THEN** the two are shown in different highlight groups

#### Scenario: Completing a partial reference

- **WHEN** the user types `/gr` and presses `<Tab>` with a `grammar` skill discovered
- **THEN** it completes to `/grammar`

#### Scenario: Completion opted out

- **WHEN** `prompt_completion = false`
- **THEN** no completion is offered at the prompt

### Requirement: Availability Across Operations

The system SHALL support skill references in `replace`, `explain`, `ask` and
`gloss`.

#### Scenario: Skills in a code operation

- **WHEN** a skill is referenced in a replace instruction
- **THEN** its contents are injected alongside the selection and the change description
