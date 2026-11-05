# Code Review: PR #44 — Fix V1 failing where the email-templates table does not exist

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/44
**Author:** Max Don
**Status:** Merged (4209d46)

## Summary

At target 1, V1 added a foreign key to `phoenix_kit_email_templates`, which core
3.x no longer creates, so a fresh database failed there. The key is now added
behind a nested `to_regclass` check.

## Verification performed

- **The trigger is real.** On a database migrated by core 3.3,
  `to_regclass('public.phoenix_kit_email_templates')` is NULL, and core's update
  task writes a literal `version: N` into the host's file
  (`phoenix_kit.update.ex:1507`), so a file pinned to V1 does run this.
- **Nesting is the right shape.** PL/pgSQL plans each statement when it first
  reaches it, so the inner `::regclass` is never resolved when the outer check is
  false. `AND`ing them would not guarantee that.
- **No sibling hazard.** The only other reference to the table is V2's import,
  which already has its own `to_regclass` guard. `phoenix_kit_settings` and
  `phoenix_kit_users` exist on core 3.3.
- **V2 after a keyless V1 works,** and the PR's test covers it.

## Findings

### IMPROVEMENT - MEDIUM — The moduledoc still said V1 was unchanged — FIXED

It read "At target 1, V1 is byte-for-byte what it always was (the drift guard pins
it)", which this PR made false, and "V1's frozen guard would try to re-add the old
FK", which now holds only where the table exists. This moduledoc is what AGENTS.md
tells people to read before changing DDL, so both sentences were corrected.

### NITPICK — `fk_guard/5`'s comment ended up on the wrong function — FIXED

`optional_fk_guard/5` was inserted between `fk_guard/5` and its long comment, so
the explanation of why `on_delete` is left out of the match sat above the wrong
function, run together with the new comment. The functions are reordered so each
sits under its own comment.

### NITPICK — No direct assertion for the branch where the table exists — ADDED

`migrations_v2_test.exs` now asserts V1 creates the key where the table exists.
This is a direct statement of the PR's claim rather than a gap closed: the test
passed before any change, and inverting the guard also fails three existing V2
tests that depend on the key.

## Validation

The fixes from this review pass, checked together on the final tree:

- `mix precommit`: passed (compile with warnings as errors, unused-lock check, Hex
  audit, format, strict Credo, Dialyzer with its two existing ignored warnings).
- `mix test`: 726 tests, 0 failures, integration tests included, on a scratch
  database. The baseline before any change was 721 tests, 0 failures.
- `mix gettext.extract --check-up-to-date`: passed.
