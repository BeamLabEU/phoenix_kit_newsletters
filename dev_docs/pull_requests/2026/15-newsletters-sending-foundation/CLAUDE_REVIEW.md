# PR #15: Phase 1 "Sending Foundation" — Send Settings (SendProfile) and per-profile delivery

**Author**: @timujinne
**Reviewer**: GLM-5.2, 4 rounds × 2 independent agents (reviewer + component-architect)
**Status**: ✅ Reviewed, fixes applied
**Date**: 2026-07-14

## Goal

Integrations hold connection keys and nothing else. Everything about *how* a
campaign is sent — which account, at what rate, with which signature and reply-to —
belongs to the newsletters module. That is a **Send Profile**.

Several profiles may point at the **same** integration: one Brevo connection can
back a slow, signed newsletter profile and a fast transactional one. Profiles are
what a broadcast selects; the integration is only where the keys live.

- `SendProfile` schema + context (53f4f8c), Send Settings admin (de923f9).
- `DeliveryWorker` resolves the profile and sends through its integration (603ee80).
- Markdown rendering moved off the retired `earmark` to `MDEx` (589391e, after
  d9b468f restored a dependency an upstream commit had dropped while `content.ex`
  still called `Earmark.as_html`).

## Verified correct (no action needed)

Checked against the running Hydra Force dev app, not only against the tests:

- **Profiles that share an integration stay independent.** Two profiles created on
  the same Brevo SMTP connection — one slow and signed (60/hour, 5s pause), one
  fast and plain (5000/hour, no pause) — and a broadcast pinned to either resolves
  to exactly that profile. Rate, signature and reply-to live on the profile; keys
  live on the integration.
- **`enabled` is a real kill-switch.** A broadcast pinned to a disabled profile does
  not send from it — it falls through to the default, so an operator can stop a
  sender whose `from_email` got blacklisted without deleting the profile.
- **A disabled profile can never be the default.** `is_default: true` with
  `enabled: false` → `get_default_send_profile/0` returns `nil`; re-enable the same
  row and it is returned. The filter really is `enabled`.
- **Only one default can exist**, and the database enforces it, not just the UI —
  the partial unique index `idx_nl_send_profiles_default` rejects a second one.
- **Permanent failures cancel; transient ones retry.** `blocked`, `deleted`,
  `not_configured`, `invalid_smtp_port` and `unsupported_provider` → `{:cancel, _}`;
  `timeout`, `econnrefused` and unrecognised reasons → retried.

## BUG - HIGH (found and fixed): blocked recipients inflated the bounce count threefold and burned every retry

`DeliveryWorker` treated *every* delivery failure the same way. A recipient who was
blocked or deleted is not a failure to retry — but the worker returned `{:error, _}`,
so Oban retried it **3 times**, and each attempt incremented `bounced_count`. One
blocked address therefore recorded **three bounces** against a campaign that had
never bounced, and burned its retry budget doing it.

`permanent_failure?/1` now recognises blocked and deleted recipients and returns
`{:cancel, reason}`, which Oban does not retry. `record_permanent_failure/2` records
the outcome without ever touching `bounced_count`, and `"blocked"` joins
`@valid_statuses` on `Delivery` so the state is representable (c03b554).

## BUG - MEDIUM (found and fixed): the `enabled` toggle did nothing, and could not be switched off anyway

Two bugs stacked on top of each other:

1. **The flag was decorative.** `DeliveryWorker` resolved a profile without ever
   checking `enabled`, so disabling one changed nothing — the campaign kept sending
   through it.
2. **It could not be unchecked.** The editor used a raw `<input type="checkbox">`
   with no hidden `false` companion, so an unchecked box submits *nothing* and the
   changeset never saw `false`. Even after fixing (1), an operator could not have
   used it.

`resolve_send_profile/1` now honours the flag (c03b554), and the editor uses the
canonical `<.checkbox>` / `<.textarea>` components, which carry the hidden input
(e8c67d5).

## BUG - MEDIUM (found and fixed): `SendProfile` would have broken every prefixed install

The schema omitted `use PhoenixKit.SchemaPrefix`, so it hard-coded the default
prefix and would have looked for its table in the wrong schema on any multi-tenant
or low-privilege install. Caught by the conformance test upstream added while this
PR was in review — a good argument for merging `main` in before shipping (470bee5).

## Scoped back deliberately

The blocklist check was first wired to `RateLimiter.check_limits/1`, which also
enforces un-gated global caps (10k/hour). That would have throttled **all**
application mail and capped bulk broadcasts — a limit nobody asked for, arriving as
a side effect. Narrowed to `check_blocklist/1`; deliberate send pacing is Phase 5's
job, where it can be configured per profile.

## Gate

Full suite green, including the module's first test infrastructure
(`test/support/data_case.ex`, `test_repo.ex`, a real `test_helper.exs`) — the
delivery worker had no way to be tested before this PR.

The bounce-count and retry behaviour is pinned by `delivery_worker_test.exs`; the
resolution, kill-switch and failure-classification behaviour above was re-checked
live. Real sends go out through both a Brevo SMTP integration and SES.

---

## Round 2 — full-PR review at merge (2026-07-19)

**Scope:** the whole of PR #15 as merged (`6649893`), covering the parts round 1
didn't touch — CRM-list broadcasts, the safe-unsubscribe flow (internal-list +
CRM-contact + RFC 8058 one-click), and the admin LiveViews — plus the three
post-round-1 follow-up commits (`dc4402a`, `2d125e6`). By this point the branch
had already been through several dedicated GLM batch reviews (see the other
`docs/superpowers/specs/reviews/2026-07-1[5-8]-*.md` files archived alongside this
PR), so this pass focused on what those rounds could plausibly have missed rather
than re-litigating settled design choices. Four parallel agents each read a
functional slice in full (CRM source + broadcaster; unsubscribe controller +
routes; broadcast editor/details LiveViews; lists/members/broadcasts LiveViews),
findings were independently verified by reading the actual code before acting on
them.

### BUG - HIGH (found and fixed): `scope=list` unsubscribe showed "success" even when nothing was unsubscribed

**File:** `lib/phoenix_kit/newsletters/web/unsubscribe_controller.ex`, `process_unsubscribe/2`

This is the exact bug pattern `dc4402a` already found and fixed once in this same
function — for the `scope=all` CRM branch — just present on the sibling
`scope=list` (original, non-CRM) branch too, which nothing in that fix touched:

```elixir
{:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
  Newsletters.unsubscribe_user(list_uuid, user_uuid)   # result discarded
  conn |> put_flash(:info, "You have been unsubscribed from this list.") |> redirect(...)
```

`Newsletters.unsubscribe_user/2` returns `{:error, :not_found}` whenever no
`ListMember` row matches `(list_uuid, user_uuid)` — a stale token (list deleted,
membership already removed by an admin, email sat in an inbox past that point) —
and the controller showed the success flash regardless, leaving the user
subscribed with no error surfaced anywhere. There was no test at all for this
branch (only the missing-token branch was covered), so nothing would have caught
a regression here either.

Fixed to match the `scope=all`/CRM branch's shape: branch on the result, show the
existing success flash on `{:ok, _}`, a "please try again" error flash on
`{:error, _}`. Added `process_unsubscribe_scope_list_test.exs` (mirroring the
existing `process_unsubscribe_scope_all_test.exs`) covering both the real-success
and the stale-token cases — **not run in this sandbox** (no Postgres/Docker
available here to back `PhoenixKitNewsletters.DataCase`); needs a real `mix test`
pass before merge.

### IMPROVEMENT - MEDIUM (found and fixed): the `"blocked"` delivery status was invisible in the admin UI

**Files:** `lib/phoenix_kit/newsletters/web/broadcast_details.ex`,
`broadcast_details.html.heex`

Round 1's fix added `"blocked"` to `Delivery.@valid_statuses` specifically so
blocklisted recipients wouldn't inflate `bounced_count`/`failed` metrics. But
`broadcast_details.ex`'s `gettext_delivery/1` and `delivery_badge_class/1` had no
clause for it (fell through to the raw untranslated string, styled like
`"pending"`), and the Delivery Stats summary card had no tile for it at all — so
the exact metric round 1 protected from pollution was simply absent from the one
screen an operator would look at to understand a low send count. Added a
`"blocked"` clause to both label/badge functions and a "Blocked" stat tile
(`get_delivery_stats/1` already group-by-counts on `status` dynamically, so no
context change was needed — it was purely a UI gap).

### Checked and confirmed correct (no action needed)

- **CRM/internal-list consistency** — batching (`insert_all` in chunks of 500 for
  both recipient sources), email case-insensitivity (CITEXT columns), idempotent
  opt-out/remove-from-list, single-transaction enqueue, and the blocklist check
  (`check_blocklist/1`) all apply identically to both recipient sources. No drift
  found between the two code paths.
- **One-click unsubscribe (RFC 8058)** — every branch (valid token, unverifiable
  token, unresolvable contact/list, repeat POST) falls through to the
  unconditional `send_resp(conn, 200, "")`; the CSRF-exempt pipeline in
  `routes.ex` scopes to exactly the two one-click routes, nothing broader.
  Cross-token-shape confusion (an internal-list token handed to the CRM one-click
  endpoint) can't crash or mutate the wrong scope — it falls through to a
  harmless no-op.
- **`broadcast_editor.ex`/`broadcast_details.ex`** — `mount/3` does no querying
  (all in `handle_params/3`); switching `source_type` correctly clears the
  now-irrelevant `list_uuid`/`crm_list_uuid`; no raw `<input type="checkbox">`
  recurrence of the SendProfile `enabled`-toggle bug; a forged `crm_list_uuid` is
  safe (cast-guarded lookup, re-validated server-side by `Broadcaster.send/1`).
- **Lists/Members/Broadcasts LiveViews** — no `mount/3` queries, no N+1s, empty
  states use `<.empty_state>`, `broadcasts.ex`'s filter correctly round-trips
  through the URL via `handle_params/3`.

### Noted, not fixed (pre-existing or deliberately out of scope)

- **Per-broadcast Send Profile has no admin UI.** `Broadcast.send_profile_uuid`
  and `DeliveryWorker.resolve_send_profile/1` both exist and work, but neither
  `broadcast_editor.ex` nor its template render a picker for it — every broadcast
  created through the admin UI gets `send_profile_uuid: nil` and falls back to
  the default profile. This matches the phase-1 plan's own scoping (Task D4 only
  wires the schema/worker resolution order; D5's live test attached a profile to
  a broadcast outside the admin UI). Flagging since it means the PR's flagship
  "two profiles on one integration" scenario has no way to be chosen per-broadcast
  from the panel yet — worth a follow-up ticket, not a fix folded into this pass.
- **CRM preflight re-queries on every `validate` event**, including plain
  keystrokes in the Subject field, when `source_type == "crm_list"` — no gate
  comparing incoming vs. current `crm_list_uuid`/`source_type`, no
  `phx-debounce`. Performance-only (cost scales with CRM list size), not a
  correctness bug — left as a follow-up.
- **Stale `subscriber_count` after `list_members.ex`'s "Remove" action**,
  **silent 50-row pagination cap with no pagination UI**, **"Add all users"
  capping at 1000 users silently**, and **`list_members.ex`'s status filter not
  round-tripping through the URL** (unlike the sibling fix in `broadcasts.ex` in
  this same PR) — all confirmed by diffing against pre-PR `newsletters.ex` /
  `list_members.ex`: none of this code was touched by PR #15 (the "ui-canon"
  pagination round explicitly scoped itself to the OOM bug class and empty
  states, not to whether pagination is reachable at all). Real gaps, but
  pre-existing and out of this PR's blast radius — logged here for the record,
  not fixed in this pass.

### Gate (round 2)

`mix compile --warnings-as-errors`, `mix format --check-formatted`, and
`mix credo --strict` all clean. `mix dialyzer` run separately (slow gate, see
commit). **`mix test` could not be run in this sandbox** — no Postgres/Docker
available to back the DataCase-backed suite (`test/support/data_case.ex`
requires a live `PhoenixKitNewsletters.Test.Repo` connection). All DataCase tests
including the new `process_unsubscribe_scope_list_test.exs` need a real run
before merge/release.
