# Code Review: PR #20 — Deliveries: record the CRM contact and make enqueue idempotent

**Reviewed:** 2026-07-22
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/20
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** a70148c
**Status:** Merged

## Summary

Adds `crm_contact_uuid` to `Delivery`, and makes `Broadcaster`'s recipient
enqueue idempotent via `insert_all(..., on_conflict: :nothing)` against three
V155 partial unique indexes on `phoenix_kit_newsletters_deliveries`
(`(broadcast_uuid, user_uuid)`, `(broadcast_uuid, crm_contact_uuid)`,
`(broadcast_uuid, recipient_email)`, each `WHERE ... IS NOT NULL`).

## Issues Found

### 1. [MEDIUM] Idempotency tests are sequential only, not concurrent
**File:** `test/phoenix_kit/newsletters/broadcaster_idempotency_test.exs` (whole file)
**Confidence:** 65/100

The PR title says "make enqueue idempotent," and the DB-level mechanism
(verified against core's V155 migration DDL) is genuinely race-safe by
construction — `ON CONFLICT DO NOTHING` with no `conflict_target` catches a
violation of *any* unique index on the table, so two concurrent
`insert_all` calls for the same broadcast+recipient are serialized by
Postgres itself, not by app-level logic. But every test in this file resets
`status` to `"draft"` and re-calls `Broadcaster.send/1` **sequentially** — none
spawn two overlapping enqueue attempts to demonstrate the constraint holds
under actual concurrency. This is a test-coverage gap, not a shipped
correctness bug (the fix is DB-enforced, not app-level), so left unfixed —
a genuinely concurrent test (e.g., two `Task.async` calls racing
`process_batch/5` for the same broadcast) would be stronger evidence than
static reasoning about Postgres semantics, but isn't blocking.

### 2. [NITPICK] `on_conflict: :nothing` with no `conflict_target` also swallows a PK collision
**File:** `lib/phoenix_kit/newsletters/broadcaster.ex:264-273`
**Confidence:** 40/100

The no-arbiter `ON CONFLICT DO NOTHING` also silently drops a (vanishingly
unlikely) `uuid` primary-key collision the same way it drops the intended
V155 dedup conflicts — UUIDv7 collision probability makes this a non-issue in
practice. Not fixed.

### 3. [NITPICK] `total_recipients` can be written twice per send
**File:** `lib/phoenix_kit/newsletters/broadcaster.ex:110-134`
**Confidence:** 30/100

Optimistic write before the transaction, then possibly overwritten again if
`count_deliveries/2` drifted. Functionally correct (confirmed by existing
tests), just an extra round-trip in the common case. Not fixed.

## What Was Done Well

- The dedup mechanism is real and DB-enforced — not a check-then-insert race.
  Verified directly against core's V155 migration DDL and CHECK constraints
  (in the sibling `phoenix_kit` checkout), not just the PR's own comments.
- `insert_all` bypasses schema autogenerate/changesets — verified `uuid`,
  `inserted_at`/`updated_at` are all set explicitly in `process_batch/5`, so no
  missing-timestamp/missing-uuid regression.
- `Oban.insert_all/1` only ever runs for rows Postgres actually returned
  (`RETURNING`), so a resend creates zero new Oban jobs for already-delivered
  recipients.
- `Delivery.validate_not_both_owners/1` mirrors the DB CHECK's mutual-exclusion
  clause exactly; `crm_contact_uuid` is deliberately excluded from the
  "somebody addressable" validation, matching the DB CHECK's intentional
  non-XOR design.
- Throttle-spacing `offset` advances by `inserted_count` (not requested batch
  size), so resends don't waste throttle spacing re-processing duplicates.
- `crm_contact_uuid` is a proper soft reference (no FK), consistent with the
  existing `crm_list_uuid`/`send_profile_uuid` convention, and degrades
  correctly when CRM isn't installed.

## Verdict

**Approved with fixes not required** — no correctness bugs found; the DB-level
dedup mechanism is real and race-safe by construction. The one gap (finding
#1) is test coverage, not shipped behavior, and is left as a documented
follow-up rather than blocking this release.
