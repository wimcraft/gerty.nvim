# language-settings Specification

## Purpose

One language configuration shared by `translate`, `gloss` and `word`, switchable
mid-session without touching the config file or restarting — because which
language you are reading changes more often than anything else in the setup.

## Requirements

### Requirement: Shared Language Configuration

The system SHALL keep one language configuration — source, target, context
lines and learner level — shared by every language operation.

#### Scenario: One setting serves three operations

- **WHEN** the language pair is configured
- **THEN** `translate`, `gloss` and `word` all use it unless individually overridden

### Requirement: Runtime Language Switching

The system SHALL allow the language settings to be changed during a session.
Changes SHALL be in-memory only, written back to no file and surviving no
restart.

#### Scenario: Setting the pair directly

- **WHEN** `set_language({ source = "pl", target = "uk" })` is called
- **THEN** subsequent language operations use that pair, and the user is told what it changed to

#### Scenario: Unknown field

- **WHEN** `set_language` is given a field that is not part of the language configuration
- **THEN** the call fails naming the unknown field

#### Scenario: Reading the current settings

- **WHEN** `get_language()` is called
- **THEN** a copy is returned, so mutating it does not change the session settings

### Requirement: Language Presets

The system SHALL offer a picker over configured language pairs, so that
switching between the languages the user actually reads takes one keystroke.

#### Scenario: Picking a pair

- **WHEN** `select_language()` is invoked with presets configured
- **THEN** each pair is offered with its languages named in full rather than as codes
- **AND** choosing one applies it for the session

#### Scenario: No presets configured

- **WHEN** `select_language()` is invoked with no presets
- **THEN** the user is told to use `set_language()` instead

### Requirement: Language Names In Prompts

The system SHALL send language names rather than ISO codes to the model,
falling back to the raw code for an unrecognised one.

#### Scenario: Codes are expanded

- **WHEN** a prompt is built for the pair `de` to `en`
- **THEN** it names German and English, rather than asking the model to interpret the codes

#### Scenario: Unrecognised code

- **WHEN** a code has no known name
- **THEN** the raw code is used, which is still better than nothing
