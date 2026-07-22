# Code Review: PR #24 — S4-E: remove the legacy list system (companion to core V156)

**Reviewed:** 2026-07-22
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/24
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** abff4d2
**Status:** Merged

## Summary

Companion removal to core's V156 migration, which migrated every legacy
newsletters list into CRM and dropped `phoenix_kit_newsletters_lists`,
`..._list_members`, and `broadcasts.list_uuid`. Removes ~4,000 lines: the
List/ListMember schemas and CRUD, the list-management admin UI (`list_editor`,
`list_members`, `lists`, their templates, routes, nav tab), the
`newsletters_list` broadcast source end-to-end (`Broadcaster`,
`DeliveryWorker`, `UnsubscribeController`), and bumps the core dep floor to
`~> 1.7 and >= 1.7.207`.

## Issues Found

None. This is an unusually thorough and carefully-documented removal PR.
Specifically checked and found correct:

- **`Broadcast.validate_source_reference/1`**: the catch-all clause now does
  `_ -> changeset` instead of requiring a (now nonexistent) `list_uuid` — since
  `@valid_source_types` no longer includes `"newsletters_list"`,
  `validate_inclusion/3` already rejects anything else earlier in the
  changeset pipeline, so this is correctly unreachable rather than a silently
  weakened validation.
- **`Broadcaster.resolve_recipients/1`**'s new catch-all clause: logs a
  warning and resolves to `[]` instead of crashing with a
  `FunctionClauseError` if a stray row somehow still carries an unknown
  `source_type` — a defensive backstop, not a live path (V156 re-points every
  row, and the changeset no longer admits the old value).
- **`BroadcastEditor.recipient_source_missing?/1`**'s catch-all clause
  (`defp recipient_source_missing?(_assigns), do: true`) is NOT a regression —
  it's the third clause of a 3-clause function, correctly falling through only
  when neither the `crm_list` nor `user_group` clause matched (fails closed,
  matching the comment: "unreachable in normal flow... but fails closed rather
  than crashing").
- **`UnsubscribeController`**: verified the "polite dead end" claim for
  already-delivered legacy `%{user_uuid:, list_uuid:}` tokens (still verifiable
  under the shared "unsubscribe" salt for up to `Phoenix.Token`'s 7-day
  `max_age`, since nothing can invalidate one flavor of a salt without
  invalidating all of it). Every entry point (`unsubscribe/2`,
  `process_unsubscribe/2` for both `scope=list` and `scope=all`,
  `one_click_unsubscribe/2`) now falls through such a token to the same
  friendly "invalid/expired" UX instead of a `CaseClauseError` (500) — and the
  new `legacy_list_token_test.exs` pins exactly this at all four entry points.
- **`DeliveryWorker`**: the `user_group`/`crm_list` unsubscribe-token and
  preferences-URL clauses are unaffected; the removed `newsletters_list`
  clause's absence doesn't leave a gap since no code can construct that
  recipient shape anymore.

## What Was Done Well

- Exceptional in-code documentation: every removal explains *why* the
  remaining behavior is still correct, not just *what* was deleted.
- `legacy_list_token_test.exs` is a well-targeted regression test suite
  specifically for the "stray old link, no crash" contract — moduledoc
  explicitly notes it replaces the old (now-inverted) test that checked the
  opposite (that the flavor *worked*).
- Correctly identifies and documents the one loose end left for a future
  change: `phoenix_kit_newsletters_broadcasts.source_type`'s DB-level
  `DEFAULT 'newsletters_list'` is core-owned DDL, harmless since every write
  path sets the value explicitly, and flagged as a natural V157 accumulator
  item rather than worked around here.
- `mix.exs`/`mix.lock` core dep bump to `1.7.207` is consistent with the
  documented release-coupling requirement (V156).

## Verdict

**Approved.** No correctness bugs found. This is the cleanest PR in the batch
reviewed in this pass — thorough, well-tested, and honest about its own edges.
