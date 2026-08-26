# provider-configuration Specification

## Purpose

Declaring which AI backends gerty can reach, and resolving those declarations
into usable providers at `setup()` time. Configuration names providers and the
models each one can reach — nothing more. There are no roles: no model is
designated "the translation one" or "the fast one", because a role name is a
claim about a model that goes stale the moment it is repointed.

## Requirements

### Requirement: Provider Declaration By Alias

The system SHALL accept a `providers` map whose keys are aliases chosen by the
user. The alias is the identity of the provider throughout the plugin: it is
what is typed as `$alias` at a prompt, what appears in pickers and the status
line, and what `default` and `op_defaults` refer to.

#### Scenario: Declaring several providers

- **WHEN** `setup()` is called with `providers = { pi = {...}, claude = {...}, ["local"] = {...} }`
- **THEN** three providers are available under the aliases `pi`, `claude` and `local`
- **AND** `config.provider_names` lists them sorted alphabetically, giving pickers a stable order

#### Scenario: No providers declared

- **WHEN** `setup()` is called with no `providers` key, or an empty map
- **THEN** a single `pi` provider is created with its own defaults
- **AND** the plugin is fully usable without any provider configuration

### Requirement: Provider Type Resolution

The system SHALL resolve each provider spec against a provider *type*, which
supplies the transport, capabilities and command construction. The `type` field
SHALL default to the alias itself, so an alias that names a known type needs no
`type` field.

#### Scenario: Alias names a known type

- **WHEN** a provider is declared as `pi = { models = {...} }`
- **THEN** the `pi` type is used, with no `type` field required

#### Scenario: Alias differs from the type

- **WHEN** a provider is declared as `["local"] = { type = "lmstudio", models = {...} }`
- **THEN** the `lmstudio` type is used under the alias `local`

#### Scenario: Alias names no known type and none is given

- **WHEN** a provider is declared as `foo = {}` and `foo` is not a known type
- **THEN** `setup()` fails with a message naming the alias and listing every known type

### Requirement: Model List Normalisation

The system SHALL accept each entry of a provider's `models` list either as a
plain model id string or as a table with `id`, and optional `name` and
`billing`. A `name` SHALL default to the `id`.

#### Scenario: String entries

- **WHEN** a provider declares `models = { "claude-sonnet-5", "claude-opus-5" }`
- **THEN** both are available for selection, labelled by their ids

#### Scenario: Table entries with a friendly label

- **WHEN** a provider declares `models = { { id = "kilo/deepseek/deepseek-v4-pro", name = "DeepSeek V4 Pro" } }`
- **THEN** the picker shows `DeepSeek V4 Pro` while the request uses the full id

#### Scenario: Malformed entry

- **WHEN** a `models` entry is neither a string nor a table carrying a non-empty `id`
- **THEN** `setup()` fails with a message naming the provider alias and the index of the offending entry

### Requirement: Current Model Defaulting

The system SHALL give every provider a current model, resolved in order:
the provider's explicit `model`, then the first entry of `models`, then the
type's own default model. A provider whose type has no default model and which
declares no models SHALL run whatever its CLI is already configured to run.

#### Scenario: Model defaults to the first listed

- **WHEN** a provider declares `models = { "a", "b" }` and no `model`
- **THEN** its current model is `a`

#### Scenario: Explicit model outside the list

- **WHEN** a provider declares `model = "claude-opus-5"` and `models = { "claude-sonnet-5" }`
- **THEN** its current model is `claude-opus-5`
- **AND** `claude-opus-5` is prepended to its model list, so the picker can return to it

### Requirement: Billing Tags

The system SHALL accept an optional `billing` string on a provider and on each
model. `billing` SHALL be display-only and never consulted when deciding
behaviour. A model SHALL inherit its provider's `billing` unless it overrides
it.

#### Scenario: Provider-level tag is inherited

- **WHEN** a provider declares `billing = "Codex subscription"` and a model without its own tag
- **THEN** that model is displayed with `[Codex subscription]`

#### Scenario: Per-model override for a mixed provider

- **WHEN** a provider tagged `"Codex subscription"` declares a model tagged `"Kilo, pay-per-token"`
- **THEN** that model is displayed with `[Kilo, pay-per-token]` and its siblings keep the provider's tag

#### Scenario: Disambiguating identical model names

- **WHEN** one provider reaches `claude-sonnet-5` through a metered gateway and another through a flat-rate subscription
- **THEN** their billing tags distinguish them in every picker and hint window

### Requirement: Default Provider Resolution

The system SHALL resolve a global default provider, used by any operation
without its own `op_defaults` entry. An explicit `default` SHALL be used when
given; otherwise the first alias alphabetically SHALL be used.

#### Scenario: Explicit default

- **WHEN** `setup()` is called with `default = "pi"`
- **THEN** operations without their own default route to `pi`

#### Scenario: No default given

- **WHEN** `setup()` declares providers `claude`, `local` and `pi` with no `default`
- **THEN** the default is `claude`, the first alphabetically

#### Scenario: Default names an undeclared provider

- **WHEN** `default` names an alias that is not in `providers`
- **THEN** `setup()` fails with a message listing the configured aliases

### Requirement: Per-Operation Default Providers

The system SHALL accept an `op_defaults` map from operation name to provider
alias, overriding the global default for that operation only. Keys SHALL be
limited to the five model-backed operations: `replace`, `explain`, `ask`,
`translate`, `gloss`.

#### Scenario: Routing the language operations locally

- **WHEN** `op_defaults = { translate = "local", gloss = "local" }` and `default = "pi"`
- **THEN** `translate` and `gloss` use `local`, while `replace`, `explain` and `ask` use `pi`

#### Scenario: Unknown operation name

- **WHEN** `op_defaults` contains a key that is not one of the five operations
- **THEN** `setup()` fails with a message listing the known operation names

#### Scenario: Unknown provider alias

- **WHEN** an `op_defaults` value names an alias that is not in `providers`
- **THEN** `setup()` fails with a message naming the operation and listing the configured aliases

#### Scenario: `word` takes no provider

- **WHEN** the user looks for a way to route `word` to a provider
- **THEN** none exists, because `word` runs a dictionary binary rather than a model

### Requirement: Configuration Validation At Setup

The system SHALL validate the whole configuration during `setup()` and fail
immediately on any error, rather than at the first call that would have used
the bad value. Every failure message SHALL name what was wrong and list the
valid alternatives.

#### Scenario: A typo is caught at startup

- **WHEN** a configuration contains a misspelled operation, provider alias, or provider type
- **THEN** `setup()` raises with a message naming the offending value and the accepted set
- **AND** no operation has to be invoked to discover the error

#### Scenario: Language presets are checked

- **WHEN** a `language_presets` entry is missing a `source` or a `target`
- **THEN** `setup()` fails with a message saying every preset needs both

### Requirement: Chat Endpoint Configuration

The system SHALL support providers backed by an OpenAI-compatible
`/chat/completions` endpoint, and SHALL provide `lmstudio` and `ollama` presets
that fill in the usual local endpoint and a temperature of `0.2`. `endpoint`
and `temperature` SHALL be overridable per provider. A chat provider without a
resolvable endpoint SHALL fail at `setup()`.

#### Scenario: Using a preset

- **WHEN** a provider declares `type = "lmstudio"`
- **THEN** its endpoint is `http://localhost:1234/v1/chat/completions` and its temperature is `0.2`

#### Scenario: Overriding a preset's endpoint

- **WHEN** a provider declares `type = "ollama", endpoint = "http://box:11434/v1/chat/completions"`
- **THEN** requests go to the overridden host

#### Scenario: Generic endpoint with no preset

- **WHEN** a provider declares `type = "openai_compat"` without an `endpoint`
- **THEN** `setup()` fails with a message showing the expected endpoint form

#### Scenario: Local, unauthenticated only

- **WHEN** a chat provider is configured
- **THEN** no authentication header or secret handling is applied, and the request is issued unauthenticated

### Requirement: Custom Provider Types

The system SHALL accept a provider type table in place of a type name, and
SHALL accept a `build_command` override on an individual provider. A
`build_command` SHALL receive the fully resolved provider — carrying its
current model and `extra_args` — plus per-call options.

#### Scenario: Supplying a whole type

- **WHEN** a provider declares `type = <table with build_command>`
- **THEN** that table supplies the transport, capabilities and command construction

#### Scenario: Type table missing build_command

- **WHEN** a provider's `type` is a table without `build_command`
- **THEN** `setup()` fails with a message listing the known type names and stating the table requirement

#### Scenario: Per-call model reaches the command builder

- **WHEN** an operation is invoked with a per-call `model`
- **THEN** `build_command` sees that model on the provider it receives, with no extra plumbing

### Requirement: List Fields Are Replaced, Not Merged

The system SHALL replace list-valued configuration wholesale rather than
merging it element by element with the defaults. This applies to `providers`
and the `models` lists inside them, to `language_presets`, and to
`dictionary.command`.

#### Scenario: Overriding a default that has entries

- **WHEN** the user sets `dictionary.command = { "trans" }` while the default is `{ "trans", "-b" }`
- **THEN** the resolved command is `{ "trans" }` and not `{ "trans", "-b" }`
