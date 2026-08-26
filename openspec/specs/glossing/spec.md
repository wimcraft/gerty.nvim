# glossing Specification

## Purpose

The `gloss` operation: the grammar and vocabulary breakdown of a selection,
written for a learner at a configured level — and, with an instruction typed at
the prompt, a way to ask anything else about the same selection.

## Requirements

### Requirement: Default Grammar Breakdown

The system SHALL, when the prompt is submitted empty, explain the grammar and
vocabulary of the selection for the configured learner level, answering in the
target language, and noting anything ambiguous or idiomatic.

#### Scenario: Empty submit gives the breakdown

- **WHEN** the user selects text and submits the Gloss prompt with no instruction
- **THEN** a grammar and vocabulary breakdown for the configured learner level is returned

#### Scenario: Learner level shapes the answer

- **WHEN** the learner level is configured
- **THEN** it is named in the prompt as the audience the explanation is written for

### Requirement: Free-Form Questions About The Selection

The system SHALL treat any text typed at the prompt as an instruction to
perform against the same selection, in place of the default breakdown.

#### Scenario: Asking something else

- **WHEN** the user types a question at the Gloss prompt
- **THEN** that question is answered about the selection, and no grammar breakdown is produced
- **AND** the answer is still written in the target language

### Requirement: Shared Language-Operation Behaviour

The system SHALL apply the same context handling, coverage anchoring, exact
selection capture, read-only guarantee and float presentation that `translate`
uses.

#### Scenario: Context is supplied but not glossed

- **WHEN** a gloss request is built
- **THEN** surrounding lines are sent as context the model is told not to act on

#### Scenario: Whole selection is covered

- **WHEN** the selection spans several sentences
- **THEN** the closing instruction requires all of it to be covered, and names the answer's language

#### Scenario: Buffer untouched

- **WHEN** a gloss resolves
- **THEN** the answer opens in a float and nothing is written to the buffer

### Requirement: Operation-Specific Response Field

The system SHALL constrain a gloss answer on a chat provider to a field named
after what the operation produces, distinct from the translation field.

#### Scenario: A gloss is not a translation

- **WHEN** a gloss runs on a chat provider
- **THEN** its answer is constrained to `grammar_notes`
- **AND** it is not constrained to `translation`, which would return a translation instead of a gloss

### Requirement: Skill Injection

The system SHALL support `#name` skill references in a gloss instruction,
injecting the named skill's contents alongside the task description.

#### Scenario: Glossing with a skill

- **WHEN** the user types an instruction containing `#mentor` at the Gloss prompt
- **THEN** that skill's contents accompany the request and its name appears in the status text

### Requirement: Per-Call Overrides

The system SHALL accept `source`, `target`, `context_lines` and
`learner_level` per call.

#### Scenario: Glossing for a different level

- **WHEN** `gloss({ learner_level = "beginner" })` is invoked
- **THEN** that call writes for a beginner and the session setting is unchanged
