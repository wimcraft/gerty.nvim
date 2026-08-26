# answer-cache Specification

## Purpose

Making a re-read free. Reading a text in another language means looking at the
same paragraph repeatedly, so a repeated lookup returns instantly, recent
lookups can be revisited, and lines already looked up are visibly marked.

## Requirements

### Requirement: Result Caching

The system SHALL cache the results of `translate`, `gloss` and `word` in memory
for the session, and SHALL serve a repeated lookup from the cache without
issuing a request.

#### Scenario: Repeating a lookup

- **WHEN** the same selection is translated a second time with everything unchanged
- **THEN** the cached answer opens immediately, marked as cached, and no request is sent

#### Scenario: Session-scoped only

- **WHEN** the editor is restarted
- **THEN** the cache is empty, because nothing is written to disk

#### Scenario: Clearing the cache

- **WHEN** `clear_cache()` is invoked
- **THEN** every cached answer is dropped

### Requirement: Cache Key Completeness

The system SHALL key the cache on everything that affects the answer: the
selected text, the surrounding context, the language settings, the instruction
where one applies, and the provider and model that produced it.

#### Scenario: Switching model invalidates

- **WHEN** the same selection is translated after switching to a different model
- **THEN** the cache misses and a fresh request is made, because a different model gives a different answer

#### Scenario: Changing context invalidates

- **WHEN** the surrounding lines change
- **THEN** the cache misses, because the context was part of what produced the answer

#### Scenario: Keys cannot collide

- **WHEN** a key is built from several parts
- **THEN** they are joined with a separator byte that cannot occur in prose

### Requirement: Forced Refresh

The system SHALL accept a per-call flag that bypasses the cache and issues a
fresh request.

#### Scenario: Asking again for a different answer

- **WHEN** a language operation is invoked with `refresh = true`
- **THEN** the cache is bypassed, a fresh request is made, and the new answer replaces the cached one

### Requirement: Lookup History

The system SHALL keep a most-recent-first list of completed lookups for the
session, bounded in length, and SHALL let the user revisit one without
re-running the request.

#### Scenario: Revisiting a lookup

- **WHEN** the user opens the history and picks an entry
- **THEN** the editor jumps back to where the lookup came from, if that buffer and line still exist
- **AND** the cached answer is shown without sending a request

#### Scenario: Repeating a lookup reorders rather than duplicates

- **WHEN** a lookup already in the history is performed again
- **THEN** it moves to the front rather than appearing twice

#### Scenario: Answer no longer cached

- **WHEN** a history entry's answer has fallen out of the cache
- **THEN** the user is told to look it up again, and no request is sent on their behalf

#### Scenario: History is bounded

- **WHEN** the number of lookups exceeds the limit
- **THEN** the oldest entries are dropped

#### Scenario: Clearing history

- **WHEN** `clear_history()` is invoked
- **THEN** the list is emptied and the cache is left intact

### Requirement: Persistent Lookup Marks

The system SHALL leave a persistent sign on every line a translate or gloss
answer covered, so that scrolling past a passage shows at a glance whether it
has already been looked up. The mark SHALL outlive the float.

#### Scenario: Marking a passage

- **WHEN** a translation resolves, or is served from cache
- **THEN** each covered line is marked with a sign

#### Scenario: Marks persist

- **WHEN** the answer float is closed
- **THEN** the marks remain, unlike the dim highlight, which only shows while the request is in flight

#### Scenario: Clearing marks

- **WHEN** `clear_marks()` is invoked with a buffer, or with none
- **THEN** that buffer's marks, or every buffer's marks, are cleared
