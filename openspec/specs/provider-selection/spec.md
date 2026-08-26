# provider-selection Specification

## Purpose

Choosing which provider and model serve a given request, at three levels of
precedence: the session default, a per-operation default, and a single call.
Every model can serve every operation, so selection is a matter of pointing at
one — never of picking a model that has been designated for the task.

## Requirements

### Requirement: Provider Resolution Order

The system SHALL resolve the provider for every model-backed operation in a
single place, applying, in descending precedence: a per-call provider, the
operation's `op_defaults` entry, and the global default.

#### Scenario: Per-call provider wins

- **WHEN** `explain({ provider = "claude" })` is called while the default is `pi`
- **THEN** the request runs on `claude`

#### Scenario: Per-operation default applies

- **WHEN** `translate()` is called with no provider, `op_defaults.translate = "local"`, and default `pi`
- **THEN** the request runs on `local`

#### Scenario: Global default applies

- **WHEN** `replace()` is called with no provider and no `op_defaults` entry for `replace`
- **THEN** the request runs on the global default

### Requirement: Inline Provider Selection With `$alias`

The system SHALL let a leading `$alias` token at any text prompt select the
provider for that one call, above every configured default. The token SHALL be
removed from the instruction before the prompt is built. A `$` token that does
not name a configured provider SHALL be left in the instruction untouched.

#### Scenario: Routing one call

- **WHEN** the user types `$claude how does this function get called?` at the Explain prompt
- **THEN** the request runs on `claude`
- **AND** the instruction sent to the model is `how does this function get called?` with no `$claude` token

#### Scenario: Unknown token is not eaten

- **WHEN** the user types `$notaprovider do a thing`
- **THEN** the request runs on the configured default
- **AND** the text `$notaprovider do a thing` reaches the model unchanged, because silently eating part of a prompt is worse than ignoring a typo

#### Scenario: A `$` elsewhere in the sentence

- **WHEN** the instruction contains a `$` that is not the leading token
- **THEN** no provider selection occurs and the instruction is untouched

#### Scenario: Aliases select providers, not models

- **WHEN** the user wants a specific model for one call
- **THEN** `$alias` is not the mechanism, because model ids such as `kilo/deepseek/deepseek-v4-pro` are impractical to type at a prompt
- **AND** a per-call `model = "..."` or the model picker is used instead

### Requirement: Inline Reference Card

The system SHALL display a static reference window beside any text prompt,
listing the providers that can be named with `$alias` and the skills that can
be named with `#name`. The card SHALL list one entry per line, and SHALL close
when the prompt resolves, whether it was submitted or cancelled.

#### Scenario: Card contents

- **WHEN** a prompt opens with several providers configured
- **THEN** each provider is listed as `$alias (current-model) [billing]`, in sorted order

#### Scenario: Card is not a completion popup

- **WHEN** the reference card is open
- **THEN** it never takes focus and never intercepts a keystroke

#### Scenario: Only one provider configured

- **WHEN** a single provider is configured
- **THEN** the provider section is omitted, because there is nothing to choose between

### Requirement: Flat Model Picker

The system SHALL provide `select_model()`, which offers one flat list of every
model on every configured provider. Choosing an entry SHALL set both the global
default provider and that provider's current model, in a single choice.

#### Scenario: One list across providers

- **WHEN** `select_model()` is invoked with three providers configured
- **THEN** every model from all three appears in one list, labelled `alias: model-name [billing]`
- **AND** the prompt shows which provider and model are currently default

#### Scenario: Picking switches both provider and model

- **WHEN** the user picks a model belonging to `claude`
- **THEN** the default provider becomes `claude` and `claude`'s current model becomes the picked one
- **AND** subsequent requests on `claude` use it

#### Scenario: Per-operation routing is not disturbed

- **WHEN** the user picks a `claude` model while `op_defaults.translate = "local"`
- **THEN** `translate` still runs on `local`, because switching the default should not drag an operation off a provider it was routed to deliberately

#### Scenario: Narrowing to one provider

- **WHEN** `select_model({ provider = "local" })` is invoked
- **THEN** only that provider's models are offered

#### Scenario: No models configured

- **WHEN** `select_model()` is invoked and no provider declares any models
- **THEN** the user is told to add `models` to a provider, and nothing is changed

### Requirement: Session-Scoped Selection

The system SHALL treat every runtime selection as in-memory and session-scoped.
No selection SHALL be written back to the user's configuration, and none SHALL
survive a restart.

#### Scenario: Setting the default provider

- **WHEN** `set_provider("claude")` is called
- **THEN** the default changes for the session and the user's config file is untouched

#### Scenario: Querying what an operation resolves to

- **WHEN** `get_provider("translate")` is called
- **THEN** the alias that `translate` currently resolves to is returned

### Requirement: Per-Call Model Override

The system SHALL accept a per-call `model` on every model-backed operation,
overriding the provider's current model for that call only. The override SHALL
NOT be written back onto the shared provider.

#### Scenario: Pinning a model for one keybinding

- **WHEN** `replace({ provider = "pi", model = "kilo/deepseek/deepseek-v4-pro" })` is invoked
- **THEN** that call uses the named model on `pi`
- **AND** `pi`'s current model is unchanged for every later call

### Requirement: Capability Guard For Tool-Dependent Operations

The system SHALL refuse an operation that cannot work on the selected provider,
before any request is issued or any spinner shown. Only `ask` requires a
provider with its own tools, because it is defined as editing whatever files
are needed and has nothing to degrade to.

#### Scenario: `ask` on a chat-only provider

- **WHEN** `ask` resolves to a provider with no tools
- **THEN** the call fails immediately with a message naming the provider and explaining that the operation needs a provider with its own tools
- **AND** no request is sent and no spinner is shown

#### Scenario: Other operations adapt instead of refusing

- **WHEN** `replace`, `explain`, `translate` or `gloss` resolves to a chat-only provider
- **THEN** the operation proceeds, adapting its mechanism to what the provider can do

### Requirement: Provider Visibility During A Request

The system SHALL show which provider is serving an in-flight request, but only
when more than one provider is configured.

#### Scenario: Several providers configured

- **WHEN** a request runs with three providers configured
- **THEN** the status text includes `@alias`

#### Scenario: One provider configured

- **WHEN** a request runs with a single provider configured
- **THEN** the alias is omitted, because there is nothing to tell it apart from
