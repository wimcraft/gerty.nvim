# constrained-decoding Specification

## Purpose

Making a local chat model answer with the answer, rather than with a narration
of how it plans to answer. An OpenAI-compatible server compiles a JSON schema
into a decoding grammar, which is enforcement rather than instruction — prompt
wording and thinking toggles are suggestions a small reasoning-tuned model can
and does ignore. This is a latency feature as much as a correctness one: tokens
spent narrating are tokens not spent answering.

## Requirements

### Requirement: Operations Declare Their Response Field

The system SHALL have each prompt declare the JSON key its answer should arrive
in, as a property of the prompt rather than of the provider. The field name
SHALL be chosen to name the content the operation produces.

#### Scenario: Each operation names its own field

- **WHEN** a prompt is built for `translate`, `gloss`, `explain` or a chat-model `replace`
- **THEN** it declares `translation`, `grammar_notes`, `answer` or `replacement` respectively

#### Scenario: The field name steers the model

- **WHEN** a field name is vague, such as `output` or `explanation`
- **THEN** the model narrates inside the string, because the grammar constrains only the shape
- **AND** a field naming the content commits the model to producing it before it can start narrating

#### Scenario: The field can override the system prompt

- **WHEN** a gloss prompt is answered through a field named `translation`
- **THEN** a translation comes back rather than a gloss
- **AND** this is why the field belongs to the operation that built the prompt, not to a provider that cannot know which operation is calling it

#### Scenario: An operation that wants no constraint

- **WHEN** a prompt is built for `ask`
- **THEN** no response field is declared and no schema is applied

### Requirement: Automatic Schema Application

The system SHALL compile a declared response field into a JSON schema and
attach it to every request made to an OpenAI-compatible provider, with no
configuration required. The schema SHALL require exactly the declared field and
SHALL forbid additional properties.

#### Scenario: Every chat request is constrained

- **WHEN** any operation with a response field runs on a chat provider
- **THEN** the request carries `response_format` of type `json_schema`, marked strict, requiring that field

#### Scenario: The same provider serves several operations

- **WHEN** one chat provider serves `translate`, `gloss`, `explain` and `replace`
- **THEN** each request is constrained to that operation's own field
- **AND** no separate provider has to be declared per operation

#### Scenario: The schema cannot go missing

- **WHEN** a chat provider is used for any constrained operation
- **THEN** the schema is applied, because it is not an opt-in property that a provider can be declared without

#### Scenario: CLI providers ignore it

- **WHEN** an operation with a response field runs on a CLI provider
- **THEN** no schema is applied and the prompt is passed through as text

### Requirement: No Decoding Sentinel

The system SHALL NOT constrain the first character of an answer. A schema
`pattern` forcing a leading space was previously used to avoid a delimiter
collision at position 0; it has been removed because it derails generation
without providing the protection it was kept for.

#### Scenario: A sentinel derails generation

- **WHEN** the answer is constrained to begin with a standalone space
- **THEN** generation is pushed into a token path that is off-distribution for a tokenizer that merges the space into the following word
- **AND** on real input this produced empty answers and answers prefixed with junk

#### Scenario: Quote protection comes from the prompt

- **WHEN** a translation of quote-initial or multi-quote dialogue is requested
- **THEN** the quotation marks are preserved by the closing instruction the prompt appends, not by any constraint on the first character

#### Scenario: A guard is re-measured, not inherited

- **WHEN** a measured guard exists and the failure it guards against is later fixed another way
- **THEN** the guard SHALL be re-measured rather than kept on the strength of the original result
- **AND** a guard that has outlived its reason can begin causing the failure it was added to prevent

### Requirement: Control Characters Are Removed

The system SHALL strip control characters from a decoded answer, preserving
tabs and newlines.

#### Scenario: A stray control character

- **WHEN** a model emits a control character in its answer
- **THEN** it is removed rather than rendered, because displayed raw it appears as garbage such as `^Z`

### Requirement: Code Answers Are Not Treated As Prose

The system SHALL mark code answers as non-prose, omitting the leading-space
sentinel from their schema and preserving leading whitespace when decoding.
Only leading blank lines and trailing whitespace SHALL be trimmed.

#### Scenario: Indentation survives

- **WHEN** a chat model returns replacement code whose first line is indented
- **THEN** that indentation reaches the buffer intact, because the lines are written back into a fixed range where it is significant

#### Scenario: Prose trimming would be destructive here

- **WHEN** the prose path's trim is applied to indented code
- **THEN** the first line's indentation is removed along with the sentinel, which is why the two paths are distinguished

### Requirement: Graceful Degradation

The system SHALL degrade to plain text when a server does not honour the
schema, rather than failing. Unwrapping SHALL be attempted and abandoned
silently when the content is not the expected shape.

#### Scenario: Server ignores `response_format`

- **WHEN** the endpoint returns prose instead of the schema's JSON object
- **THEN** the prose is used as the answer
- **AND** the only cost of an unsupported endpoint is the unconstrained behaviour

#### Scenario: Server ignores only the pattern

- **WHEN** the endpoint honours the schema but not the `pattern` constraint
- **THEN** the answer arrives without the leading sentinel and is used unchanged

### Requirement: Opting Out Per Provider

The system SHALL accept `json_schema = false` on a provider, skipping
constrained decoding for every request to it.

#### Scenario: A server the grammar hurts

- **WHEN** a provider declares `json_schema = false`
- **THEN** its requests carry no `response_format` and answers are taken as plain text

#### Scenario: Alternative tuning for reasoning models

- **WHEN** a provider declares `chat_template_kwargs`, such as enabling a thinking channel
- **THEN** those kwargs are sent with the request, letting the server strip deliberation out of the answer instead

### Requirement: Layered Response Decoding

The system SHALL distinguish the ways a chat request can fail and report which
one occurred: transport failure, malformed JSON, an API-level error object, an
unexpected response shape, and a technically valid but empty answer.

#### Scenario: Endpoint is named in failures

- **WHEN** a chat request fails
- **THEN** the error message includes the endpoint that was addressed

#### Scenario: A truncated answer is a failure

- **WHEN** the server reports that generation stopped at the token limit
- **THEN** the result is an error naming that reason, rather than a successful partial answer
- **AND** this matters most for a code replacement, where a partial answer looks valid and would be written into the buffer

#### Scenario: Empty answer

- **WHEN** the response decodes correctly but the answer is empty after trimming
- **THEN** the result is reported as an error rather than as a successful empty answer
