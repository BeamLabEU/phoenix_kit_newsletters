# Code Review: PR #30 — Make a failed broadcast retryable

**Reviewed:** 2026-07-31
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/30
**Author:** timujeen (timujinne)
**Head SHA:** a410cfbd03d52ab695479ca1217e592a2cf43293 (merged as e18faa6)
**Status:** Merged

## Summary

`Broadcaster.send/1` gains a `"failed"` clause so a broadcast that failed
terminally (the only producer is `handle_scheduled_send_failure/3`'s
`{:crm_list_not_active, _}` branch in `newsletters.ex:317`) can be sent again
once its CRM list is active. `BroadcastDetails` grows a "Retry send" button for
`status == "failed"`, wired through the existing `show_confirm` →
`confirm_action` modal, plus a `send_error_message/1` mapping so the failure
flash reads as a sentence instead of a raw tuple. Two `Broadcaster`-level tests
cover the retry and the re-fail.

I independently re-verified the core safety claim and it holds: `"failed"` is
only ever written *before* `do_send/1` runs, so a failed broadcast provably has
zero deliveries, nothing to duplicate or orphan. The enqueue is idempotent
regardless — `process_batch/5` inserts with `on_conflict: :nothing` and builds
Oban jobs only from the `RETURNING` rows (`broadcaster.ex:310-325`), so a
conflicting delivery produces no job either.

The issues below are about the parts of the change that live *outside* the
broadcaster.

## Issues Found

### 1. [BUG - MEDIUM] The PR's four new UI strings never reached the gettext catalogues — FIXED
**File:** `priv/gettext/default.pot`, `priv/gettext/{en,et,ru}/LC_MESSAGES/default.po`
**Confidence:** 100/100

`"Retry send"`, `"This will retry sending the broadcast from the beginning."`,
`"Cannot send: the CRM list is %{status}, not active."` and `"Cannot send a
broadcast with status %{status}."` were added as `gettext/1` calls but appear in
none of the four catalogues (only the pre-existing `"Failed to send: %{reason}"`
was already there). The package ships `en`/`et`/`ru`, and gettext falls back to
the raw msgid silently — so the whole retry affordance renders in English for
Estonian and Russian operators, with nothing failing anywhere to say so.

**Fix applied:** added all four msgids to `default.pot` and to each locale, hand
-edited rather than via `mix gettext.extract --merge` (the extractor regenerates
the `.pot` from `gettext` calls only, which would drop the hand-listed
`Tab.new!` labels documented in the `.pot` header). Translations written for
`et`/`ru`.

**Test added:** `i18n_test.exs` gains a catalogue-parity guard — every msgid in
`default.pot` must exist in every locale, and no locale may carry an empty
`msgstr`. The existing drift guard only covered `admin_tabs/0` labels, which is
why this class of gap could land unnoticed.

### 2. [BUG - MEDIUM] Retry acted on the page's copy of the broadcast, so a stale tab could re-send a broadcast that had moved on — FIXED
**File:** `lib/phoenix_kit/newsletters/web/broadcast_details.ex` lines 140-151 (pre-fix)
**Confidence:** 90/100

`confirm_action` passed `socket.assigns.broadcast` straight to
`Broadcaster.send/1`. That struct is a snapshot from the last `handle_params` —
this LiveView subscribes to nothing and refreshes only when the operator clicks
"Refresh". `Broadcaster.send/1`'s new `"failed"` clause therefore judges the
status *as the page last saw it*, not as the row is.

Failure scenario: a broadcast is retried from a second tab (or by a second
admin) and reaches `"sending"`/`"sent"`. The first tab still shows "Retry send".
Clicking it passes the stale `%Broadcast{status: "failed"}` through the guard
into `do_send/1`, which flips the row back to `"sending"`, overwrites `sent_at`
with the retry time, and re-resolves the audience — every list member added
since the first send has no delivery row yet, so they get one and a live Oban
job. The already-delivered recipients are protected by the V155 partial unique
indexes, but the broadcast's own status and timestamps are not, and the newly
added members are genuinely mailed off a stale click. The row then sits in
`"sending"` until `repair_stuck_sending_broadcasts/0` flips it back.

The guard is the right mechanism; it just needs a fresh row to judge.

**Fix applied:** `confirm_action` now delegates to a private `retry_send/1` that
re-reads the broadcast with `Newsletters.get_broadcast!/1` before calling
`Broadcaster.send/1`, so a broadcast that has moved past `"failed"` is refused
by the existing `{:invalid_status, status}` clause. The refusal path also
reloads the page data, so the operator ends up looking at the current status
rather than the stale `"failed"` one they clicked; a broadcast deleted out from
under the page is rescued into the same "Broadcast not found" redirect
`load_broadcast_data/1` already used.

**Tests added:** `broadcast_details_test.exs` — the retry succeeds from
`"failed"`, and a stale-`"failed"` socket over a row that is now `"sent"` is
refused with the row left untouched.

### 3. [IMPROVEMENT - MEDIUM] The humanized send-error flash was applied to only one of the two `Broadcaster.send/1` call sites — FIXED
**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.ex` lines 190-204 (pre-fix)
**Confidence:** 100/100

The GLM nitpick this PR's second commit answers ("raw Elixir tuple leaked into
the admin-facing error flash") applies verbatim to the editor's "Send now",
which had the identical `gettext("Failed to send: %{reason}", reason:
inspect(reason))`. Fixing one copy and not the other left the same refusal
rendering as a sentence on the details page and as `Failed to send:
{:crm_list_not_active, "archived"}` in the editor — worse than either
consistently, since the mapping now has to be remembered in two places.

**Fix applied:** extracted the mapping to
`PhoenixKit.Newsletters.Web.SendError.message/1` (same shape as the existing
shared `Web.Timezone` helper) and used it from both LiveViews. `send_error_test.exs`
pins all three clauses, including that the catch-all still `inspect/1`s an
unmapped reason.

### 4. [IMPROVEMENT - MEDIUM] The LiveView half of the feature had no test — FIXED
**File:** `test/phoenix_kit/newsletters/web/broadcast_details_test.exs`
**Confidence:** 100/100

Both PR tests sit at the `Broadcaster` level. The event wiring the PR actually
adds — `show_confirm` arming `:retry_send`, `confirm_action` dispatching to it —
was untested, even though this LiveView already has a direct-callback test file
built for exactly this. A typo'd `phx-value-action` would have fallen through
`confirm_action`'s `_ ->` catch-all and silently done nothing.

**Fix applied:** three tests covering the arm, the successful retry, and the
stale-page refusal from issue #2.

### 5. [NITPICK] `"Edit send profile"` carried an empty translation in the `en` catalogue — FIXED
**File:** `priv/gettext/en/LC_MESSAGES/default.po` line 44

Pre-existing, and harmless at runtime (gettext falls back to the msgid), but it
was the one entry standing between the catalogues and the parity guard added for
issue #1. Filled in.

### 6. [OBSERVATION] A failed broadcast can be retried but not edited — NOT FIXED

`broadcast_details.html.heex:35` shows "Edit" only for `status == "draft"`. Since
the only way to reach `"failed"` is an inactive CRM list, an operator whose list
was archived permanently has exactly one in-app affordance — a retry that will
keep failing the same way. Repointing the broadcast at a different list needs the
editor.

Deliberately not fixed: widening the Edit gate is a change to the editor's status
contract (what a re-save does to `sent_at`, `total_recipients`, and a broadcast
mid-`"sending"`), which is well beyond this PR's scope and wants its own design
pass. Recorded so the limitation is on file rather than rediscovered.

### 7. [OBSERVATION] A pre-existing hole one step over: an enqueue that fails mid-transaction is not retryable at all — NOT FIXED

`do_send/1` flips the broadcast to `"sending"` at `broadcaster.ex:96-102`,
*outside* the `repo.transaction/1` that creates the deliveries. If that
transaction returns `{:error, _}`, the row is left in `"sending"` with zero
deliveries, and `handle_scheduled_send_failure/3`'s catch-all clause only logs a
warning. `repair_stuck_sending_broadcasts/0` then matches it (status
`"sending"`, and with no delivery rows it is trivially absent from
`Delivery.non_terminal_broadcast_uuids_query/0`) and marks it `"sent"` — a
broadcast that reached nobody, reported as sent, and outside the retry path this
PR adds.

Pre-existing, not introduced here, and the fix is a status-lifecycle change
rather than a follow-up to this PR. Filed as `FOLLOW_UP.md`-grade context.

### 8. [OBSERVATION] The first commit message describes a change that isn't in the diff — NOT FIXED

`ebf9c27` claims "broadcasts.html.heex: the status filter dropdown was missing a
'failed' option"; the file isn't in that commit, and the option has been there
since `9497d55` (PR #16). Cosmetic, and unfixable now without rewriting merged
history.

## What Was Done Well

- **The retry reuses the pre-send validation rather than adding a retry-specific
  path.** `send_if_valid/1` is untouched, so "retry against a still-broken cause"
  can't drift from "send against a broken cause" — and the accompanying test
  pins it.
- **The `@doc` explains *why* `"failed"` is admissible**, and points at the one
  producer, which is exactly the fact a future reader needs to reason about
  delivery-row safety.
- **The second commit's test tightening is the right instinct** — asserting the
  delivery rows exist *and* that there is exactly one per member pins the
  no-duplication property directly instead of inheriting it from a sibling test.
- **The confirm-modal wiring mirrors `cancel_broadcast` exactly**, so it inherits
  the admin `live_session` authorization boundary with nothing new to audit.

## Validation

`mix quality.ci` (format check + `credo --strict` + dialyzer): clean.
`mix test`: 118 passed, 0 failures — **but 190 tests are excluded in this
environment**: there is no PostgreSQL available here, so every DB-backed test,
including the three added for issue #2 and both of the PR's own broadcaster
tests, did not run. The non-DB additions (`send_error_test.exs`, the
`i18n_test.exs` parity guards) do run and pass. The DB-backed additions need a
run against a real test DB with core V158 before they can be called verified.

## Verdict

**Approved with fixes.** The broadcaster-level change is correct and its central
safety argument holds under independent checking. Everything that needed fixing
was in the surrounding shell: an untranslated feature in a three-locale package,
a status guard fed a stale struct by the LiveView, a humanized error message
applied to one of its two call sites, and no coverage of the event wiring the PR
adds. All four are fixed here; the remaining items are recorded as limitations
rather than changed.
