# code-explanation Specification

## Purpose

The `explain` operation: ask a question about a selection and get prose back,
in a scratch float, with a guarantee that nothing was written. Where the
provider allows it, the answer is grounded in the whole repository rather than
in the snippet alone.

## Requirements

### Requirement: Read-Only Guarantee

The system SHALL guarantee that `explain` writes nothing. The guarantee SHALL
be enforced at the provider's own tool level where possible, and stated in the
prompt regardless, so a provider that ignores the flag still degrades to
prompt-level intent.

#### Scenario: Tool denial at the CLI level

- **WHEN** `explain` runs on a CLI provider
- **THEN** that provider's file-writing tools are denied via its own flags
- **AND** the prompt also states that this is a read-only task

#### Scenario: The shell must be denied too

- **WHEN** only the edit and write tools are denied
- **THEN** the guarantee does not hold, because a model reaches for a shell heredoc instead and writes the file anyway
- **AND** the shell is therefore denied alongside the edit tools

#### Scenario: Read tools remain

- **WHEN** file-writing tools are denied
- **THEN** the reading, searching and globbing tools remain, which is all the operation needs

### Requirement: Repository-Grounded Answers

The system SHALL, for a provider with its own tools, give the model the
repository root and the selection's file and line anchor, and instruct it to
read whatever it needs — definitions, callers, tests, related configuration —
rather than answering from the snippet alone.

#### Scenario: Answering from the repository

- **WHEN** `explain` runs on a tool-capable provider
- **THEN** the model may read any file in the repository to answer
- **AND** the answer is asked to reference real symbols and real paths rather than describing the code in general terms

### Requirement: Snippet-Only Answers On Chat Providers

The system SHALL swap the repository-exploration instruction for a snippet-only
one when the provider has no tools, and SHALL instruct the model to say plainly
when something cannot be determined from the selection.

#### Scenario: Explaining on a local model

- **WHEN** `explain` runs on a chat-only provider
- **THEN** the model is told it cannot open any other file, and to answer from the selection and its own knowledge

#### Scenario: The instruction is swapped, not softened

- **WHEN** a model with no file access is told to read whatever it needs from the repository
- **THEN** it does not decline — it invents plausible file contents and cites paths it never opened
- **AND** the instruction is therefore replaced rather than merely weakened

#### Scenario: A question about the selection itself

- **WHEN** the question is about the selected text rather than about how it fits the codebase
- **THEN** a chat-only provider is a suitable choice, and the operation does not refuse it

### Requirement: Narration Suppression On Small Models

The system SHALL append a closing instruction, for non-tool-capable providers
only, telling the model to begin its reply with the explanation itself and not
to restate the question, the selection, or what it is about to do.

#### Scenario: Recency is the lever

- **WHEN** the same instruction is placed in the preamble instead of last
- **THEN** it has no effect, because the habit is only beaten by the last thing read before generation

#### Scenario: Tool-capable providers are untouched

- **WHEN** `explain` runs on a CLI provider
- **THEN** no closing instruction is appended, because those providers do not have the habit

### Requirement: Answer Presentation

The system SHALL show the answer in a scratch float rather than writing it into
the buffer, formatted as Markdown and not wrapped in a code fence.

#### Scenario: Answer opens in a float

- **WHEN** an explain request resolves successfully
- **THEN** a bordered, centred float opens containing the answer, titled with the file name and line range

#### Scenario: Nothing is persisted

- **WHEN** the float is closed
- **THEN** its contents are discarded and no buffer was modified

### Requirement: Default Question

The system SHALL supply a default question when the prompt is submitted empty,
rather than sending an empty instruction.

#### Scenario: Empty submit

- **WHEN** the user submits the Explain prompt with no text
- **THEN** the model is asked what the code does, why it exists, and how it is used elsewhere in the repository

#### Scenario: Cancelled prompt

- **WHEN** the user cancels the prompt
- **THEN** no request is sent
