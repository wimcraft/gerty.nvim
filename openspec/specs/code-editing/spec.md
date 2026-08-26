# code-editing Specification

## Purpose

The `replace` operation: select code, describe a change, and have only that
selection rewritten. The defining constraint is containment — a model given
access to the repository must not wander off and edit anything else.

## Requirements

### Requirement: Selection-Scoped Rewriting

The system SHALL rewrite only the visually selected range, replacing it with
the model's output. Surrounding lines SHALL be sent as context so the
replacement fits, but SHALL NOT be rewritten.

#### Scenario: Rewriting a selection

- **WHEN** the user selects lines, invokes `replace`, and describes the change
- **THEN** exactly those lines are replaced with the result
- **AND** the configured number of surrounding context lines was sent to inform the rewrite

#### Scenario: The filetype is supplied

- **WHEN** a replace request is built
- **THEN** the buffer's filetype accompanies the selection, so the model writes in the right language

#### Scenario: Line-based by design

- **WHEN** a characterwise or blockwise selection is made
- **THEN** the operation still acts on whole lines, because rewriting code is a different contract from quoting prose

### Requirement: Containment On Tool-Capable Providers

The system SHALL, for a provider with its own file tools, instruct the model to
write the replacement to a temporary file and to modify no other file. The
temporary file SHALL be removed after the request resolves, on every outcome.

#### Scenario: Writing through a temp file

- **WHEN** `replace` runs on a CLI provider
- **THEN** the model is told to write the replacement, and nothing else, to a named temporary path
- **AND** the buffer is updated from that file's contents

#### Scenario: The indirection is the containment

- **WHEN** a model with full file access performs the edit
- **THEN** it has no reason to touch the working tree, because the only file it was asked to write is a scratch path

#### Scenario: Temp file cleanup

- **WHEN** the request succeeds, fails, or is cancelled
- **THEN** the temporary file is removed

### Requirement: Direct Return On Chat-Only Providers

The system SHALL, for a provider with no file tools, ask for the replacement as
the answer itself and write that into the range. The prompt SHALL be adapted so
the model is never told to write to a path it cannot open.

#### Scenario: Replacing with a local model

- **WHEN** `replace` runs on a chat-only provider
- **THEN** the model returns the replacement text directly, constrained to a `replacement` field
- **AND** the buffer range is updated from that answer

#### Scenario: The instruction is swapped, not softened

- **WHEN** the provider has no tools
- **THEN** the temp-file instruction is replaced by an instruction to return only the replacement code
- **AND** this matters because telling a model to write to a path it cannot open does not make it decline, it makes it claim it did

#### Scenario: Indentation is preserved

- **WHEN** the replacement's first line is indented
- **THEN** that indentation reaches the buffer intact

#### Scenario: Same operation either way

- **WHEN** the user invokes `replace` on either kind of provider
- **THEN** the keybinding, the prompt and the result in the buffer are the same, and only the carrying mechanism differs

### Requirement: Commentary Suppression

The system SHALL instruct the model to return code alone, with no commentary,
explanation or markdown fences. Where a chat model wraps the entire answer in a
code fence regardless, the system SHALL remove it.

#### Scenario: A whole-answer fence is stripped

- **WHEN** a chat model returns the replacement wrapped in an opening and closing fence
- **THEN** the fence lines are removed and the code between them is written to the buffer

#### Scenario: A fence within the replacement is kept

- **WHEN** the replacement legitimately contains a fenced block partway through
- **THEN** it is preserved, because only a fence wrapping the whole answer is removed

### Requirement: Selection Tracking Across Edits

The system SHALL track the selected range while the request is in flight, so
that concurrent editing does not cause the result to be written to the wrong
place. If the range no longer exists when the answer arrives, the write SHALL
be abandoned.

#### Scenario: Text is inserted above the selection

- **WHEN** the user edits elsewhere in the buffer while the request runs
- **THEN** the replacement still lands on the originally selected lines

#### Scenario: The selection is destroyed

- **WHEN** the selected range is deleted before the answer arrives
- **THEN** the user is warned that the selection was destroyed and the replace is abandoned

### Requirement: Empty Or Unreadable Result

The system SHALL leave the buffer untouched and warn when the model returns
nothing usable.

#### Scenario: Nothing came back

- **WHEN** the temporary file is unreadable or empty, or the chat answer is empty
- **THEN** the buffer is unchanged and the user is told the response was empty or unreadable
