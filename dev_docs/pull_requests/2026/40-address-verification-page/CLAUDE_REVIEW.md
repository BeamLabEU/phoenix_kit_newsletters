# Code Review: PR #40 — Add an address verification page backed by the Emails verification engine

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/40
**Author:** Tymofii Shapovalov
**Status:** Merged (97179fe)

## Summary

A new subtab, Address verification (`/admin/newsletters/verification`). The
audience is a CRM list or a set of roles, resolved with the sender's own
`sendable_recipients/1`; verdicts come from the Emails engine through a soft
bridge (`EmailVerification`, `Code.ensure_loaded?` + `apply/3`). The page
filters by status, paginates, starts a batch and follows its progress over
PubSub. `VerificationRows` holds the table as plain data.

## Verification performed

The review checked the page's assumptions against the engine source
(`phoenix_kit_emails` checkout, `verification.ex` and `verification/batch*.ex`),
not just the PR's own fake:

- **Batch contract.** `Batch.states` = `queued running done cancelled`, and
  `source_types` already include `newsletters_crm_list` /
  `newsletters_user_group`, so `start_batch/4` is not refused for its source.
  The final PubSub message carries `done` or `cancelled`, which is exactly
  `@terminal_batch_states`.
- **Result keys.** `results_for/1` / `statuses_for/1` are keyed by the address
  *as given*, so `VerificationRows.build/2`'s `Map.get(results, email)` matches
  even for mixed-case addresses; the engine does the case-folding itself.
- **`summary/1`** always returns all five keys, so `Map.fetch!(@summary, status)`
  in the template cannot raise (and the bridge's fallback has all five too).
- **Out-of-order snapshots** are handled the way the engine documents
  (ignore a lower `processed`); the terminal message re-reads the batch.
- **URL state.** `?list=` and `?roles[]=` are cast with `Ecto.UUID.cast/1`
  before any query; `?status=` is whitelisted before `String.to_existing_atom/1`;
  `Plug.Conn.Query.encode/1` renders the role list as `roles[]=`.
- **Degradation.** `:unavailable` / `:disabled` skip all engine and audience
  work (`handle_params` has a separate clause), and every bridge read rescues
  and masks addresses in log lines.
- `mix test`: 646 tests, 0 failures (10 excluded: real-engine tags).

## Findings

### 1. IMPROVEMENT - MEDIUM — the audience summary was re-read on every page or filter patch

`load_table/2` also assigned `EmailVerification.summary(emails)`. The engine
builds it from `statuses_for/1`, a status read of the *whole* audience, so each
"Next" click (and, with a status filter, a second whole-audience read on top of
the one `VerificationRows.table/6` already makes) cost O(audience) for counts
that had not changed. The engine allows batches of up to 100,000 addresses.

**Fixed:** the summary moved to `load_summary/1`, called when the audience is
resolved (or forced), when a batch starts and when a batch ends — the only
moments verdicts or the audience change. Test: a filter patch over the same
audience does not call `summary/1`; a different audience does. The fake engine
now reports `summary/1` calls like its other reads.

### 2. IMPROVEMENT - MEDIUM — `start_batch/4` runs in the LiveView process

The engine's doc says the call "blocks for as long as it takes to insert the
items (a few seconds for the maximum of 100,000 addresses): a LiveView should
not call it from its own process for a large list." The page does exactly that
in `handle_event("start_batch", ...)`; the admin's page is frozen for that
time (other users are unaffected, and the heartbeat lives in the transport, so
the connection survives).

**Not fixed:** the right fix is `start_async/3` plus `handle_async/3`, but this
module's LiveView tests call callbacks directly on a hand-built socket, which
has no transport for a task to report to; it would mean rebuilding the 1100-line
test harness for a bounded, few-second pause that only the clicking admin sees.
Recorded here so the next change to that handler picks it up.

### 3. NITPICK — a second subscription when the audience is switched back

`subscribe_once/2` remembers one uuid. Audience A (running batch a) → B (batch b)
→ A subscribes to `a` again, so its messages arrive twice and the terminal one
reloads the table twice. Harmless (progress is monotone, the reload idempotent);
the bridge has no unsubscribe to fix it with, so a set of subscribed uuids would
be the cure. Not changed.

### 4. NITPICK — the "already running" guard is per-tab

AGENTS.md calls the start "guarded server-side". The guard re-reads the latest
batch right before starting, which closes a stale page and a double click, but
two admins clicking within the engine's insert window can both pass it. The
engine does not dedupe by source. Worth knowing; no action.

### 5. NITPICK — audience and tables are resolved on both renders

`handle_params/3` runs on the dead and the connected render, so a large
audience is resolved and looked up twice on first load. This follows the repo's
stated convention (work in `handle_params`, not `mount`), and gating on
`connected?/1` would blank the first paint. No change.

No functional bugs found.
