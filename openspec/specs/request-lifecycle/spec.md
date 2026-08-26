# request-lifecycle Specification

## Purpose

How every request runs and reports itself: one job runner for all subprocesses,
per-line progress anchored to the code it concerns, and cancellation that
resolves honestly. Nothing gerty does may block the editor.

## Requirements

### Requirement: Fully Asynchronous Execution

The system SHALL run every subprocess asynchronously and SHALL never block the
editor while a request is in flight.

#### Scenario: Working during a request

- **WHEN** any operation is running
- **THEN** the user can keep editing, navigating and reviewing elsewhere

#### Scenario: Concurrent requests

- **WHEN** several requests are started before the first resolves
- **THEN** each runs independently and each maintains its own progress display

### Requirement: Single Job Ownership

The system SHALL run every subprocess it starts — provider CLIs, HTTP requests
and the dictionary binary — through one runner with one monotonic ID space, so
that identifiers can safely key shared UI state.

#### Scenario: One ID space

- **WHEN** a CLI request and an HTTP request run concurrently
- **THEN** they receive distinct ids and neither overwrites the other's progress display

#### Scenario: Missing binary

- **WHEN** a configured command does not exist
- **THEN** the failure is reported like any other error rather than tearing down the caller

### Requirement: Exactly-Once Completion

The system SHALL resolve every job exactly once. A cancelled job SHALL report
itself as cancelled, and the killed process's eventual real exit SHALL be
ignored.

#### Scenario: Cancellation reports honestly

- **WHEN** a request is cancelled
- **THEN** it reports as cancelled, not as a failure or as whatever partial output the killed process left behind

#### Scenario: No double resolution

- **WHEN** a process exits after its job was already resolved
- **THEN** the later exit is dropped

### Requirement: Progress Display Anchored To The Code

The system SHALL show a spinner and the most recent line of output as virtual
text anchored to the line the request concerns, and SHALL name the operation,
the provider where relevant, and any skills in use.

#### Scenario: Progress above the selection

- **WHEN** a request concerning a range is running
- **THEN** progress is shown as virtual text at that range

#### Scenario: Bracketing a range

- **WHEN** `replace`, `translate` or `gloss` acts on a multi-line range
- **THEN** progress is shown both above and below it, and the range is dimmed to mark it as pending
- **AND** `explain`, which writes nothing back, anchors a single display above the selection instead

#### Scenario: Anchor is deleted

- **WHEN** the anchored line is deleted while the request runs
- **THEN** the display does not error

#### Scenario: HTTP responses are not streamed

- **WHEN** a request runs against an HTTP endpoint
- **THEN** no partial output is pushed to the spinner, because the body arrives at once and would flash as a wall of JSON

### Requirement: Universal Cancellation

The system SHALL provide a single cancellation entry point covering every
in-flight request, including dictionary lookups, and SHALL tear down all
associated display state.

#### Scenario: Cancelling everything

- **WHEN** `cancel_all()` is invoked
- **THEN** every in-flight job is cancelled and every spinner, dim highlight and progress display is cleared

#### Scenario: Processes are signalled

- **WHEN** a job is cancelled
- **THEN** its process is terminated after the job has been resolved

### Requirement: Distinguishable Failures

The system SHALL report the different ways a request can fail with messages
that say which occurred, and SHALL leave the buffer untouched on any failure.

#### Scenario: Non-zero exit

- **WHEN** a process exits non-zero
- **THEN** its standard error is reported, or a message naming the command and exit code when there is none

#### Scenario: Cancelled requests are silent

- **WHEN** a request was cancelled
- **THEN** no error is reported, because the user caused it deliberately

### Requirement: Transport-Neutral Prompts

The system SHALL have prompt construction produce a transport-neutral prompt —
never a CLI string and never a message array — so that any operation can be
routed to any provider at runtime without the prompt shape becoming wrong.
Conversion SHALL happen in exactly one place.

#### Scenario: One prompt, two transports

- **WHEN** the same operation is routed to a CLI provider and to an HTTP provider
- **THEN** the same prompt is folded into a command argument in one case and rendered as messages in the other

#### Scenario: System instruction on a CLI

- **WHEN** a prompt carrying a system instruction runs on a CLI provider
- **THEN** the instruction is folded into the single text blob the CLI accepts

#### Scenario: A prompt with no system instruction

- **WHEN** a prompt carries only user text
- **THEN** that text is passed through unchanged
