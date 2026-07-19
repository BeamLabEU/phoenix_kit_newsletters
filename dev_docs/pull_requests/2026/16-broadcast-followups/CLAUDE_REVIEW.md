# Code Review: PR #16 — Fix scheduled-broadcast retry loop, message_id constraint mismatch, and List-Unsubscribe headers for user broadcasts

**Reviewed:** 2026-07-19
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/16
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 2f10d0208d109be94da03f267a9555fadb586c0a
**Status:** Merged (549e396)

## Summary

Three independent bug fixes surfaced after the PR #15 merge, all in one commit:

1. `process_scheduled_broadcasts/0` retried a scheduled broadcast against an archived
   CRM list forever — `Broadcaster.send/1`'s `{:error, {:crm_list_not_active, _}}` was
   only logged, leaving `status: "scheduled"` so every scheduler tick re-fetched and
   re-failed the same broadcast. Adds a terminal `"failed"` status
   (`Broadcast.valid_statuses/0`) and transitions to it on this specific error,
   removing the broadcast from the scheduler's query.
2. `Delivery.changeset/2`'s `unique_constraint(:message_id)` named the constraint
   after Ecto's default convention, but the real DB index from core migration V79 is
   `idx_newsletters_deliveries_message_id` — the mismatch meant a real unique
   violation wasn't recognized by Ecto and re-raised as `Ecto.ConstraintError`
   instead of returning `{:error, changeset}`.
3. List-Unsubscribe / List-Unsubscribe-Post headers were only ever added for
   `crm_list` broadcasts — a `newsletters_list` (user) broadcast's
   `build_unsubscribe_url/2` returned `{url, nil}`, making the header plug a
   permanent no-op for that flavor. Generates a one-click URL from the same token for
   the user flavor too, and the one-click POST controller clause is extended to
   handle the `user_uuid`/`list_uuid` claim shape (previously fell through to a
   silent no-op `_ -> :ok`, so a mail client's List-Unsubscribe-Post request looked
   successful but never unsubscribed anyone).

## Verified correct (no action needed)

- **Constraint name matches the real index.** Checked against core
  `phoenix_kit/lib/phoenix_kit/migrations/postgres/v79.ex:169` —
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_message_id ...` — the
  new `name:` on `unique_constraint/3` is exactly right.
- **`unsubscribe_user/2` argument order** (`list_uuid, user_uuid`) matches the new
  call site in `UnsubscribeController.one_click_unsubscribe/2`.
- **`handle_scheduled_send_failure/3` reduce accumulator** — both clauses return
  `acc` unchanged (a failure, terminal or not, never increments the sent count);
  `process_scheduled_broadcasts/0`'s `{:ok, count}` return contract is preserved.
- **Trigger reality-checked**: `Broadcaster.send/1` does emit
  `{:error, {:crm_list_not_active, status}}` exactly where the fix expects it
  (`broadcaster.ex:71`), and the query scoping to `status == "scheduled"` genuinely
  excludes a broadcast once it flips to `"failed"` — confirmed by the new regression
  test's second-tick assertion.
- Test coverage is solid: a dedicated regression test for the retry loop (first tick
  fails terminally, second tick is a no-op with `updated_at` unchanged), full
  GET/POST/idempotency coverage for the new one-click user-flavor branch, and the
  `message_id` constraint test now asserts the graceful `{:error, changeset}` path
  instead of the previous `assert_raise Ecto.ConstraintError`.

## Issues Found

### 1. [BUG - MEDIUM] New "failed" broadcast status missing from the admin status filter — FIXED

**File:** `lib/phoenix_kit/newsletters/web/broadcasts.html.heex`, lines 47–60

`Broadcast.valid_statuses/0` gained `"failed"`, and both `broadcasts.ex` and
`broadcast_details.ex` correctly render it (badge class, `gettext_status/1` clause).
But the broadcasts index's status filter `<select>` dropdown was not updated — it
still only lists `draft`/`scheduled`/`sending`/`sent`/`cancelled`, so once a
broadcast lands in `"failed"` (the exact scenario this PR introduces and tests),
there is no way to filter the admin list down to it. This is the "two lists that
must stay in sync" pattern: the status enum vs. the filter dropdown drifted apart.

**Fix:** Added a `<option value="failed">` entry alongside the existing ones,
reusing the same `gettext("Failed")` msgid already present in `priv/gettext/*/default.po`
(shared with the pre-existing `Delivery` "failed" status, so translations for
`ru`/`et` already exist — no gettext catalogue changes needed).

**Confidence:** 90/100

## What Was Done Well

- Root-caused all three bugs against the actual emitting/consuming code
  (`Broadcaster.send/1`'s error tuple, the real DB index name, the header plug's
  guard) rather than guessing.
- The `handle_scheduled_send_failure/3` fix is deliberately narrow — only the
  non-retryable `{:crm_list_not_active, _}` reason is treated as terminal; other
  transient error reasons keep the original retry-forever `Logger.warning` behavior,
  which is documented as an explicit design decision in a code comment rather than
  silently generalized.
- Comments throughout explain *why*, not *what* (e.g. why the one-click endpoint
  must differ from the interactive landing-page URL — CSRF).
- Test changes are precise: the pre-existing `assert_raise Ecto.ConstraintError` test
  was flipped to assert the newly-correct graceful path instead of being deleted,
  keeping regression coverage for the exact bug fixed.

## Verdict

**Approved with fixes.** All three fixes are correct and well-tested. One
follow-up gap (missing filter option for the new status) found and fixed in this
review pass.
