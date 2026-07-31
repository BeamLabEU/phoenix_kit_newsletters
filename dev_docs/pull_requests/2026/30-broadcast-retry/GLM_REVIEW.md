# GLM Review — PR #30 (make a failed broadcast retryable)

Model: glm-5.2 via the z.ai endpoint, reviewer persona (two-stage: spec compliance, then code quality). Read-only pass over `git diff upstream/main...fix/broadcast-followups`, tracing the delivery-row lifecycle end-to-end.

## Stage 1: Spec Compliance

I traced the full retry path end-to-end. Every claim in the PR description is verified against the code:

**1. `Broadcaster.send/1` accepts `"failed"`** — `lib/phoenix_kit/newsletters/broadcaster.ex:55-57` adds the clause, delegating to the unchanged `send_if_valid/1` (`:63-68`).

**2. Re-fail safety (`validate_recipient_source` unchanged)** — `send_if_valid/1` still runs `validate_recipient_source/1` *before* `do_send/1` (`:64-67`). When the list is still archived it returns `{:error, {:crm_list_not_active, _}}` (`:77-85`) and `do_send` never runs; the broadcast's status is untouched and stays `"failed"`. Covered by `broadcaster_crm_test.exs:127-138`.

**3. "Retry send" button** — shown iff `@broadcast.status == "failed"` (`broadcast_details.html.heex:55-64`), same `show_confirm` → `confirm_action` shape as cancel.

**4. Modal wiring** — `show_confirm`/`"retry_send"` (`broadcast_details.ex:103-113`) sets assigns; the confirm button fires payload-less `confirm_action` (`broadcast_details.html.heex:20`), which reads `socket.assigns.confirm_action` and hits the `:retry_send` branch (`broadcast_details.ex:140-156`). Identical pattern to cancel.

**Delivery-row safety (the core review question) — verified safe, no duplication possible:**
- A broadcast reaches `"failed"` *only* via `handle_scheduled_send_failure` (`newsletters.ex:317-329`), invoked when `Broadcaster.send` returns `{:crm_list_not_active, _}`. That error originates in `validate_recipient_source`, which runs **before** `do_send` (`broadcaster.ex:64-67`) — so at the moment status flips to `"failed"`, **zero deliveries exist**. There are no rows to reuse, duplicate, or orphan, and no recipient was ever mailed. Confirmed there is no other production writer of `status: "failed"`.
- Even defensively, `do_send`'s enqueue is idempotent: `process_batch` uses `insert_all(..., on_conflict: :nothing)` (`broadcaster.ex:309-327`) against the V155 partial unique indexes (per-user/contact/email, documented `:275-284`), so even a double-click race inserts no duplicate rows and enqueues no duplicate Oban jobs.

**Counters / timestamps — no staleness:** `sent_count`/`delivered_count`/`opened_count`/`bounced_count` are stored columns (`broadcast.ex:24-27`) incremented by `DeliveryWorker`; since a failed broadcast never ran a delivery they're still 0 on retry. `total_recipients` was never set (0) and is set fresh on retry (`broadcaster.ex:110`, reconciled `:131-138`). `sent_at` is `nil` before retry and set to the retry time (`broadcaster.ex:101`). There is **no `failed_at` column** and no persisted failure event (only a `Logger.error` at `newsletters.ex:318`), so nothing stale to reset.

**Authorization** — `BroadcastDetails` is registered through `admin_tabs` → the host's auth-gated admin `live_session` (`newsletters.ex:125`); retry inherits that boundary identically to cancel_broadcast. No separate guard is required or expected.

**Spec Verdict:** PASS

---

## Stage 2: Code Quality

### MINOR: Retry-success test stops at status + total_recipients, never asserting deliveries/jobs were created
**File**: `test/phoenix_kit/newsletters/broadcaster_crm_test.exs:115-125`
**Problem**: The "retried once the cause is fixed" test asserts only `sent.status == "sending"` and `sent.total_recipients == length(sendable)`. It does not verify that `Delivery` rows or Oban jobs were actually produced on the retry — exactly the behavior the review brief asks about. Its sibling in the same file asserts all of that (`broadcaster_crm_test.exs:84-97`: delivery count, `user_uuid: nil`, status `"pending"`, exact email/contact sets). Because the `"failed"` clause delegates to the same shared `do_send`, delivery creation is *indirectly* covered, so this is a depth gap rather than a correctness hole — but a regression that set status/total yet skipped the enqueue (e.g. a future special-case of the failed path) would pass silently. Asserting `length(list_deliveries(sent.uuid)) == length(sendable)` here would also pin the no-duplication property directly.
**Suggestion**: After the successful retry, add `deliveries = Newsletters.list_deliveries(sent.uuid)` and assert the count equals `sendable` length (not double), all `status == "pending"`, mirroring the `:77-98` test.
**Rationale**: The whole point of this PR is that a retry re-enqueues cleanly; the test should prove the enqueue happened, not just that the status guard admitted the input.

### NITPICK: Raw Elixir tuple leaked into the admin-facing error flash
**File**: `lib/phoenix_kit/newsletters/web/broadcast_details.ex:154`
**Problem**: `gettext("Failed to send: %{reason}", reason: inspect(reason))` renders the structured reason verbatim, e.g. `Failed to send: {:crm_list_not_active, "archived"}`. It is admin-only (no secret leakage), and surfacing *why* a retry failed is genuinely useful, but the raw tuple is unlocalized and inconsistent with cancel_broadcast's generic `Failed to cancel broadcast` (`:137`).
**Suggestion**: Map known reasons to human strings (`{:crm_list_not_active, _}` → "the CRM list is not active"), falling back to a generic message.
**Rationale**: Keeps the flash readable for operators who aren't reading Elixir terms.

**Quality Summary:** 0 critical, 0 major, 1 minor, 1 nitpick
**Quality Verdict:** Ship

---

## Overall Verdict: PASS

The change is small, correctly scoped, and safe. The retry leverages the existing pre-delivery validation-failure semantics (a `"failed"` broadcast provably has zero deliveries, so there is nothing to duplicate or orphan), and the `on_conflict: :nothing` enqueue is idempotent even under a double-click race. The button/confirm wiring mirrors cancel_broadcast exactly and inherits the same admin authorization. The only actionable item is tightening the retry-success test to assert deliveries are actually created (and not duplicated) on retry — the one place the current tests under-verify the behavior this PR exists to enable.
