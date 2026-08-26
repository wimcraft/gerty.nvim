# agent-tasks Specification

## Purpose

The `ask` operation: describe a task and let the model run as a full agent with
its own tools, editing whatever files it needs — like running the provider's
CLI directly, without leaving the editor or blocking it.

## Requirements

### Requirement: Unrestricted Agentic Execution

The system SHALL run `ask` with the provider's file tools available, imposing
no read-only constraint and no output-file protocol. No selection SHALL be
required.

#### Scenario: Running a task

- **WHEN** the user invokes `ask` and describes a task
- **THEN** the model runs with its own tools and may read and edit any file needed
- **AND** no selection was required to start

#### Scenario: Editor context is supplied

- **WHEN** an ask request is built
- **THEN** the repository root and the currently open file accompany the instruction

### Requirement: Chat-Only Providers Are Refused

The system SHALL refuse `ask` on a provider without its own tools, before any
request is issued. This is the only operation that refuses rather than adapts,
because it is defined as editing whatever files are needed and has nothing to
degrade to.

#### Scenario: Refusal is immediate and explained

- **WHEN** `ask` resolves to a chat-only provider
- **THEN** the call fails with a message naming the provider and stating that the operation needs a provider with its own tools
- **AND** no spinner is shown for a request that could never have worked

### Requirement: Buffer Reconciliation

The system SHALL reconcile open buffers with the working tree after the task
completes, because the model may have edited files out from under them.

#### Scenario: Files changed on disk

- **WHEN** an ask task finishes successfully
- **THEN** open buffers are checked against their files on disk
- **AND** the user is notified that the task is done

### Requirement: Non-Blocking Execution

The system SHALL run the task asynchronously, anchoring its progress display to
the cursor line at the moment of invocation.

#### Scenario: Editing continues during the task

- **WHEN** an ask task is running
- **THEN** the editor remains fully usable and progress is shown as virtual text
