# Code Review: PR #25 — UserGroupSource: batch the CRM contact lookup (N+1 in sendable/preflight)

**Reviewed:** 2026-07-22
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/25
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 1cf41d4
**Status:** Merged

## Summary

Fixes an N+1 flagged in the #22 delta review: `UserGroupSource.sendable?/1`
issued one `CRMSource.get_contact_by_user_uuid/1` query per resolved user.
Adds `CRMSource.get_contacts_by_user_uuids/1` (a single batched
`%{user_uuid => contact}` map lookup, chunked at 5,000 uuids to stay under
Postgres's 65,535-bind-per-query ceiling) and threads it through both
`sendable_recipients/1` and `preflight/1` — the latter recomputed on every
role-checkbox click in the editor.

## Issues Found

None found. Specifically checked and confirmed correct:

- **Boolean logic preserved**: the old `sendable?/1` computed
  `not opted_out?(user)`, i.e. `not (custom_field_opted_out? or contact_opted_out?)`.
  The new batched `sendable?/2` computes
  `not custom_field_opted_out?(user) and not batch_contact_opted_out?(user, contacts_by_user_uuid)`
  — equivalent by De Morgan's, not just similar.
- **Soft-dependency contract preserved**: `get_contacts_by_user_uuids/1` gates
  on `available?()` and returns `%{}` when CRM isn't installed, same as the
  per-user path it replaces.
- **Chunking rationale is sound and necessary**: `IN ^list` binds one
  parameter per uuid; an "all users" role audience could exceed Postgres's
  65,535-bind ceiling, a bound the old per-user path never had. 5,000/chunk is
  a reasonable margin.
- **`opted_out?/1`** (the still-public, single-user function used elsewhere)
  is untouched and still correct — the batched path is a parallel
  implementation for the N-user case, not a replacement that could leave the
  single-user call sites broken.
- **Query-count tests** use a telemetry event name
  (`[:phoenix_kit_newsletters, :test, :repo, :query]`) that correctly matches
  Ecto's default `telemetry_prefix` derivation for the `PhoenixKitNewsletters.Test.Repo`
  module (module path split on `.`, snake-cased, `:query` event appended) —
  not a typo'd event name that would silently pass by asserting on an event
  that never fires.
- **`Enum.uniq/1`** is applied before chunking, so a role set with duplicate
  user resolutions (shouldn't happen, but not relied upon) can't produce
  redundant lookups or a larger-than-necessary chunk.

## What Was Done Well

- Precisely scoped: touches only the two call sites that had the N+1
  (`sendable_recipients/1`, `preflight/1`), leaves the single-user
  `opted_out?/1` path alone.
- Test coverage directly pins the fix's actual claim (query count, not just
  behavior): exactly one contacts query for N resolved users, zero when no
  users resolve — using the same telemetry-based pattern as core's own
  `timezone_label_test`.
- Clear, accurate in-code documentation of the chunking rationale and the
  Postgres bind-limit constraint that motivates it.

## Verdict

**Approved.** No correctness bugs found. Clean, well-tested, precisely-scoped
fix for the N+1 it set out to close.
