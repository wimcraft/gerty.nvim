# translation Specification

## Purpose

The `translate` operation: select foreign-language text and read it in your own
language, in a float, without the buffer ever changing. Built for reading a
novel in the editor, which is why context handling and quotation-mark fidelity
matter more here than raw speed.

## Requirements

### Requirement: Context Without Contamination

The system SHALL send the lines surrounding the selection as context the model
is explicitly told not to translate, to be used solely for resolving ambiguity
— pronouns, gender, register and idiom. Context and selection SHALL be visibly
separated in the prompt.

#### Scenario: Resolving a pronoun from the previous sentence

- **WHEN** a selection whose meaning depends on the preceding sentence is translated
- **THEN** the preceding lines are supplied as context and the answer covers only the selection

#### Scenario: Context is marked as off-limits

- **WHEN** the prompt is built
- **THEN** the context appears under a banner stating it is for context only and must not be translated
- **AND** the selection appears under a banner marking it as the text to act on

### Requirement: Complete Coverage Of The Selection

The system SHALL append a closing instruction requiring the whole selection to
be translated, every sentence, from the first word to the last.

#### Scenario: A long context block

- **WHEN** several lines of context accompany a multi-sentence selection
- **THEN** the whole selection is translated, not only its first sentence

#### Scenario: Why the closing position matters

- **WHEN** the same requirement is stated only in the opening banner
- **THEN** it stops working as context volume grows, because the banner is too far from the generation point by then

### Requirement: Output Language Anchoring

The system SHALL restate the target language in the closing instruction, even
though the system prompt already names it.

#### Scenario: Guarding against a language flip

- **WHEN** a long selection is translated
- **THEN** the closing instruction names the target language again, catching the rare case of the answer arriving in an unrelated language

### Requirement: Quotation Mark Fidelity

The system SHALL preserve quotation marks in translated dialogue.

#### Scenario: Dialogue keeps its quotes

- **WHEN** a passage of novel dialogue is translated on a chat provider
- **THEN** the quotation marks survive into the answer rather than being dropped or truncating it

### Requirement: Marks And History Follow The Text

The system SHALL track the selected range from the moment it is captured, so
that the persistent marks and the history entry point at the text itself rather
than at the rows it occupied when the request started.

#### Scenario: Lines inserted above during the request

- **WHEN** text is inserted above the selection while a translation is in flight
- **THEN** the marks land on the translated lines at their new position

#### Scenario: The selection is deleted during the request

- **WHEN** the selected lines are deleted before the answer arrives
- **THEN** the answer is still shown, because it is still worth reading
- **AND** no marks are placed and the history entry records no position to jump to

### Requirement: Buffer Is Never Modified

The system SHALL show the translation in a float and SHALL never write it into
the buffer, on any provider. Where the operation runs on a tool-capable
provider, it SHALL run under the same read-only tool denial that `explain` uses.

#### Scenario: Reading a translation

- **WHEN** a translation resolves
- **THEN** it opens in a float titled with the translated line range, and the buffer is unchanged

#### Scenario: Routed to a CLI provider

- **WHEN** `translate` runs on a CLI provider
- **THEN** that provider's file-writing tools are denied for the request

### Requirement: Exact Selection Capture

The system SHALL read the exact visual selection — characterwise, linewise or
blockwise — rather than widening it to whole lines, and SHALL handle multibyte
text and backwards selections correctly.

#### Scenario: A characterwise selection mid-line

- **WHEN** the user selects part of a line and translates it
- **THEN** only the selected characters are translated

#### Scenario: Invoked outside visual mode

- **WHEN** the operation is invoked from the command line after a selection was made
- **THEN** the previous selection's marks are used, so the call still works

#### Scenario: Empty selection

- **WHEN** the selection is empty or whitespace only
- **THEN** the user is warned and no request is sent

### Requirement: Per-Call Language Override

The system SHALL accept `source`, `target` and `context_lines` per call,
overriding the session language settings for that call only.

#### Scenario: Translating one passage from another language

- **WHEN** `translate({ source = "pl", target = "uk" })` is invoked
- **THEN** that call uses the given pair and the session settings are unchanged
