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

This containment is **prompt-level, not enforced**. Writing the temporary file
is itself a file write, so the provider's tools cannot be denied for this
operation the way they are for `explain`. Documentation SHALL describe it as an
instruction the model follows rather than a restriction it operates under.

#### Scenario: Writing through a temp file

- **WHEN** `replace` runs on a CLI provider
- **THEN** the model is told to write the replacement, and nothing else, to a named temporary path
- **AND** the buffer is updated from that file's contents

#### Scenario: The indirection removes the reason, not the ability

- **WHEN** a model with full file access performs the edit
- **THEN** it has no reason to touch the working tree, because the only file it was asked to write is a scratch path
- **AND** it retains the ability to do so, which is why this is documented as prompt-level containment

#### Scenario: Enforced containment is available

- **WHEN** the user needs `replace` to be structurally unable to touch other files
- **THEN** routing it to a chat-only provider achieves that, because such a provider has no tools at all

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
explanation or markdown fences, UNLESS a skill has opened the explanation
channel (see *Explanation Channel For Skilled Edits*), in which case commentary
is expected but is carried outside the replacement and routed away from the
buffer. Where a chat model wraps the entire answer in a code fence regardless,
the system SHALL remove it.

#### Scenario: A whole-answer fence is stripped

- **WHEN** a chat model returns the replacement wrapped in an opening and closing fence
- **THEN** the fence lines are removed and the code between them is written to the buffer

#### Scenario: A fence within the replacement is kept

- **WHEN** the replacement legitimately contains a fenced block partway through
- **THEN** it is preserved, because only a fence wrapping the whole answer is removed

#### Scenario: The fence is stripped from the code, not the explanation

- **WHEN** a chat model fences the value of the replacement field
- **THEN** the fence is removed from that field only; the explanation field is untouched

### Requirement: Explanation Channel For Skilled Edits

WHEN `replace` runs with at least one skill referenced and the channel is not
disabled by configuration, the system SHALL invite
the model to explain the change on a channel separate from the replacement so
it never reaches the buffer, and SHALL leave the depth of that explanation to
the skill. The channel is transport-specific: on an agentic provider the
replacement goes to the temp file and the explanation is the model's stdout
reply; on a chat provider the decoding grammar carries a second required key
alongside the replacement. The replacement SHALL be applied to the buffer as
usual. WHEN an explanation is present, the system SHALL show it in a float that
does NOT take focus -- `replace` is an edit operation, so the cursor SHALL stay
in the buffer being edited and the float SHALL dismiss itself on the next cursor
move -- mark the covered lines with the same persistent sign a translation uses,
and record the edit in history so the explanation can be re-opened later from
cache without another request. WHEN no usable explanation comes back — an endpoint
that dropped the second field, an agent that replied with nothing — the
replacement SHALL be applied and nothing else.

#### Scenario: A skilled edit returns an explanation

- **WHEN** the model applies the correction and returns a description of what it changed
- **THEN** the corrected text replaces the selection, the explanation opens in a float, the changed lines are signed, and a history entry points at the cached explanation

#### Scenario: No usable explanation comes back

- **WHEN** a skill is active but the response carries no non-empty explanation
- **THEN** the replacement is applied and nothing else happens — no float, no history entry

#### Scenario: The explanation does not interrupt the edit

- **WHEN** a skilled edit returns an explanation
- **THEN** the cursor remains in the edited buffer, not in the float

#### Scenario: The channel is turned off

- **WHEN** `replace_explain = false` and a skill is referenced
- **THEN** the replacement is applied, the chat grammar carries only the
  replacement field, and no float or history entry is produced

#### Scenario: A plain edit is unaffected

- **WHEN** `replace` runs with no skill referenced
- **THEN** the prompt is byte-for-byte as before, and the chat grammar has the single replacement field

#### Scenario: Re-opening the explanation

- **WHEN** the user picks a recorded skilled edit from history
- **THEN** the cached explanation is shown again and the cursor jumps to the edited lines, with no request sent

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
- **THEN** the user is warned and the replace is abandoned
- **AND** no other line is modified

#### Scenario: Position alone is insufficient

- **WHEN** the selected lines are deleted while the request is in flight
- **THEN** the tracking mark does not disappear — a point mark relocates to the deletion boundary — so the system SHALL mark the tracked range invalid on deletion and refuse to write
- **AND** without that the replacement lands on whatever moved into that position and destroys it

#### Scenario: Neither guard is sufficient alone

- **WHEN** a deleted selection is followed by a line holding identical text
- **THEN** comparing text cannot detect the deletion, and only the range's invalidation can
- **AND** when the range is edited rather than deleted, invalidation may not fire and only the text comparison can detect it
- **AND** the system SHALL therefore apply both

#### Scenario: The range is tracked from selection time

- **WHEN** the buffer is edited while the instruction prompt is still open
- **THEN** the replacement still lands on the originally selected lines, because tracking begins when the selection is taken rather than when the prompt is submitted

#### Scenario: The selection is edited rather than deleted

- **WHEN** the selected lines are changed while the request is in flight
- **THEN** the replace is abandoned, because the answer describes text that no longer exists

### Requirement: Empty Or Unreadable Result

The system SHALL leave the buffer untouched and warn when the model returns
nothing usable.

#### Scenario: Nothing came back

- **WHEN** the temporary file is unreadable or empty, or the chat answer is empty
- **THEN** the buffer is unchanged and the user is told the response was empty or unreadable
