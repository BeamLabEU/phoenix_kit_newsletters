# Code Review: PR #17 — Finalize broadcasts stuck in "sending" forever

**Reviewed:** 2026-07-19
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/17
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** merged via 18e331c (merges 1698a5e, which folds in 5da37b5 / 72eabb1)
**Status:** Merged (18e331c)

## Summary

Before this PR, nothing ever transitioned a `Broadcast` from `"sending"` to
`"sent"` — every broadcast was stuck in `"sending"` permanently once its
deliveries were created. The PR adds:

1. `Delivery.non_terminal_broadcast_uuids_query/0` — the single source of
   truth for "which broadcasts still have an incomplete delivery," driven by
   `@non_terminal_statuses` (originally just `["pending"]`).
2. `DeliveryWorker.maybe_finalize_broadcast/1` — after each delivery's status
   transition, atomically flips its broadcast to `"sent"` once every sibling
   delivery has left the non-terminal set, all inside the same transaction as
   the status write and the counter bump (`update_delivery_result/5`).
3. `Newsletters.repair_stuck_sending_broadcasts/0` — a batch sweep (called
   from `process_scheduled_broadcasts/0`) that catches broadcasts which
   finished sending before this fix existed, or whose finalize write was
   lost to a crash between statements.

Well tested for the cases it set out to cover: successful sends, terminal
bounces, blocked (suppression-list) deliveries, permanently-failed
deliveries, the repair sweep, and a real concurrent-`Task` race between the
last two workers of a broadcast.

## Issues Found

### 1. [BUG - HIGH] Broadcast finalizes to "sent" on the first still-retryable failure of its last delivery — FIXED

**File:** `lib/phoenix_kit/newsletters/workers/delivery_worker.ex`, `handle_failure/4`
(pre-existing, unchanged by this PR) interacting with the PR's new
`maybe_finalize_broadcast/1` and `Delivery.non_terminal_broadcast_uuids_query/0`
**Confidence:** 95/100

`@non_terminal_statuses` is `["pending"]` — every other `Delivery.status`
value, including `"failed"`, counts as *done* for finalization purposes.
But `handle_failure/4` (added in an earlier PR, untouched here) writes
`status: "failed"` **unconditionally**, regardless of whether the failure is
terminal (`attempt >= max_attempts`) or merely the first of up to three Oban
attempts:

```elixir
def handle_failure(delivery_uuid, broadcast_uuid, reason, terminal?) do
  case get_delivery(delivery_uuid) do
    {:ok, delivery} ->
      update_delivery_result(
        delivery, "failed", %{error: inspect(reason)},
        broadcast_uuid, if(terminal?, do: :bounced_count)
      )
    ...
```

`update_delivery_result/5` runs the delivery-status write, the counter bump,
*and* `maybe_finalize_broadcast/1` in one transaction. So a broadcast's very
last outstanding delivery hitting a single transient failure (attempt 1 of
3 — a timeout, a rate-limit response, anything not in `permanent_failure?/1`)
immediately flips the broadcast to `"sent"`, in the same transaction as that
first failed attempt — no race window or timing needed, this reproduces on
every run.

Concretely, this breaks `broadcast_details.html.heex`'s "Cancel broadcast"
button, which is gated on `@broadcast.status == "sending"` — an admin loses
the ability to cancel a broadcast that is, in fact, still trying to deliver
(Oban has two more attempts queued with backoff). The broadcast is also
permanently reported "Sent" to the admin from that point on; nothing ever
reverts it if the retry keeps failing.

Reality-checked against `Delivery.non_terminal_broadcast_uuids_query/0`'s
own doc comment, which already (correctly) flagged the risk but reasoned it
away as merely delaying the status flip — it does not delay it; it triggers
it early, deterministically, on the very first attempt.

**Fix:** Split `handle_failure/4` into two clauses on `terminal?`. The
terminal clause is unchanged (writes `"failed"` + bumps `:bounced_count` +
finalizes, as before). The non-terminal clause no longer advances
`Delivery.status` away from `"pending"` — it still records the error message
for admin visibility, but leaves status (and therefore finalization
eligibility) untouched, since Oban has already scheduled another attempt.
Updated `Delivery`'s `@non_terminal_statuses` comment to match, and updated
the pre-existing test asserting the old (buggy) `status == "failed"`
behavior for the non-terminal case. Added a regression test
(`broadcast_finalization_test.exs`) proving a still-retryable failure on a
broadcast's last delivery does **not** finalize it.

Trade-off: an individual recipient mid-retry now shows as "Pending" rather
than "Failed" in the per-delivery admin table until the retry actually
concludes (succeeds, or exhausts attempts). That's a minor, arguably more
accurate, UI change — not a functional regression — in exchange for the
broadcast-level status and the Cancel button being correct.

### 2. [OBSERVATION] `NOT IN (subquery)` is NULL-fragile — not fixed

**File:** `lib/phoenix_kit/newsletters/delivery.ex`,
`non_terminal_broadcast_uuids_query/0`

Both call sites filter with `b.uuid not in subquery(...)`. Standard SQL
gotcha: if the subquery's `broadcast_uuid` column ever produced a `NULL`
row, `NOT IN` evaluates to `NULL` (not `true`) for *every* outer row,
silently disabling finalization for every broadcast in the table, not just
the one with the bad row. In practice `Delivery.broadcast_uuid` is
`validate_required/2`'d in the changeset and this repo's core migrations
back foreign-key-style UUID columns as `NOT NULL`, so this would need an
actual data-integrity violation (a row inserted outside the changeset path)
to trigger. Flagging rather than fixing — swapping to a correlated
`WHERE NOT EXISTS` would close the gap defensively, but touches the one
piece of shared query logic both callers depend on, for a scenario that
needs a corrupt row to reach. Not worth the churn unless corrupt rows are a
real possibility here.

### 3. [NITPICK] Stale function-name reference in a comment — FIXED

**File:** `test/phoenix_kit/newsletters/workers/delivery_worker_test.exs`, line 492

Referenced `update_broadcast_counter/2`, the private helper this PR's
`maybe_bump_counter/2` refactor replaced. Corrected the comment to the new
name.

## What Was Done Well

- Root-caused the actual bug ("nothing ever finalizes a broadcast") rather
  than papering over symptoms, and centralized the completion definition in
  one query (`non_terminal_broadcast_uuids_query/0`) shared by both the
  per-delivery finalize check and the batch repair sweep — exactly the "two
  lists that must stay in sync" trap avoided instead of walked into.
- `update_delivery_result/5` correctly folds the status write, counter bump,
  and finalize check into one transaction, closing a real crash window
  (BEAM going down between the status write and the counter write) that
  existed before this PR.
- The repair sweep is a single batch `UPDATE` keyed off current row state
  (`status == "sending"`), not a read-then-write per broadcast — genuinely
  race-safe against a concurrent `DeliveryWorker` commit, and doesn't need
  its own transaction.
- Real concurrency test (`Task.async` against the shared sandbox connection,
  not just sequential calls) for the last-two-workers race — this actually
  exercises Postgres row-locking behavior rather than asserting it by
  inspection.
- Counting completion from `Delivery` rows rather than
  `sent_count`/`bounced_count` is the right call — `"blocked"` and
  permanently-`"failed"` deliveries deliberately never touch those counters
  (correctly, to avoid corrupting the bounce-rate metric), so a
  counter-based finalize predicate would have been unreachable the moment
  one recipient landed in either state. The PR's own tests cover exactly
  this.

## Validation

- `mix compile --warnings-as-errors` — clean.
- `mix format --check-formatted` — clean.
- `mix credo --strict` — clean (378 mods/funs, no issues).
- `mix test` — **could not be run**: this sandbox has no Postgres available
  (no server running, no package manager root access to install one, no
  Docker) and this repo's test suite is DB-backed (`PhoenixKitNewsletters.Test.Repo`).
  All logic above was verified by reading, not by executing the new
  regression test. **Run `mix test` (in particular
  `broadcast_finalization_test.exs` and
  `workers/delivery_worker_test.exs`) in an environment with Postgres before
  relying on this fix or publishing a release built on it.**

## Verdict

**Approved with fixes.** The core "stuck in sending forever" fix is sound
and well-tested for the cases it targets; the one gap (an untouched,
pre-existing `handle_failure/4` behavior interacting badly with the PR's new
finalize logic) is fixed and regression-tested in this pass, but that test
has only been read, not run — see Validation above.
