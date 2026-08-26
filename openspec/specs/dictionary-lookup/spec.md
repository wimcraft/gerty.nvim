# dictionary-lookup Specification

## Purpose

The `word` operation: look up the word under the cursor. No model is involved —
"what does this word mean" does not need one — so the answer is effectively
instant.

## Requirements

### Requirement: Model-Free Lookup

The system SHALL look the word up by running a configured dictionary binary,
never a model. The operation SHALL take no provider.

#### Scenario: Looking up a word

- **WHEN** the cursor is on a word and `word` is invoked
- **THEN** the configured dictionary binary is run with the language pair and the word appended
- **AND** the result opens in a float

#### Scenario: No provider applies

- **WHEN** the user looks for a way to route `word` to a provider
- **THEN** none exists, because the operation involves no model

### Requirement: Configurable Dictionary Command

The system SHALL accept the dictionary command as an argv prefix, to which the
language pair and the word are appended, and SHALL allow the language pair to
be overridden for this operation alone.

#### Scenario: Default command

- **WHEN** no dictionary command is configured
- **THEN** a one-line gloss is fetched via translate-shell

#### Scenario: Full dictionary entries instead

- **WHEN** the user configures a different argv prefix
- **THEN** that command is used, with the pair and word appended

#### Scenario: Dictionary-specific language pair

- **WHEN** `dictionary.source` or `dictionary.target` is configured
- **THEN** the lookup uses those rather than the session language pair

### Requirement: Shared Job Handling

The system SHALL run the dictionary process through the same job runner as
model requests, so that cancellation and progress display cover it too.

#### Scenario: Cancelling a lookup

- **WHEN** `cancel_all()` is invoked while a lookup is running
- **THEN** the lookup is cancelled along with every model request

#### Scenario: Progress is shown

- **WHEN** a lookup is running
- **THEN** a spinner is anchored to the cursor line naming the word being looked up

### Requirement: Absent Word Or Binary

The system SHALL distinguish no word, no entry, and a failing binary.

#### Scenario: No word under the cursor

- **WHEN** the cursor is not on a word
- **THEN** the user is warned and nothing is run

#### Scenario: No dictionary entry

- **WHEN** the binary succeeds but returns nothing
- **THEN** the user is told there is no entry for that word

#### Scenario: Binary fails

- **WHEN** the dictionary binary exits with an error
- **THEN** the error is reported, naming the binary
