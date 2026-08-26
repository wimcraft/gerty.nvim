# skills Specification

## Purpose

Reusable prompt fragments, referenced inline as `#name`. A skill is a
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
honoured anywhere in the instruction, not only at the start.

#### Scenario: Referencing a skill

- **WHEN** the user types `#refactor extract this into a helper function`
- **THEN** that skill's contents accompany the request

#### Scenario: Repeated reference

- **WHEN** the same skill is referenced twice in one instruction
- **THEN** its contents are injected once

#### Scenario: Unknown skill

- **WHEN** a `#name` does not match a discovered skill
- **THEN** no injection occurs and the text is left in the instruction

### Requirement: Skill Visibility

The system SHALL list the available skills on the inline reference card, and
SHALL name the skills in use in the status text of a running request.

#### Scenario: Skills on the reference card

- **WHEN** a prompt opens with skills discovered
- **THEN** each is listed as `#name`

#### Scenario: Skills named during a request

- **WHEN** a request runs with skills referenced
- **THEN** their names appear in the status text alongside the operation

### Requirement: Availability Across Operations

The system SHALL support skill references in `replace`, `explain`, `ask` and
`gloss`.

#### Scenario: Skills in a code operation

- **WHEN** a skill is referenced in a replace instruction
- **THEN** its contents are injected alongside the selection and the change description
