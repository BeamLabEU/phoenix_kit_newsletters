# Code Review: PR #21 — Add subscription preference center (spec §7)

**Reviewed:** 2026-07-22
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/21
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** a78e4f5
**Status:** Merged

## Summary

Adds a public, mostly-unauthenticated "preference center" page
(`PreferenceCenterLive`) reachable either via a signed `contact_uuid` token
from an email link, or from a logged-in user's account nav (which lazily
finds-or-creates a linked CRM contact). Lets a contact toggle subscription per
CRM list, opt out of everything, or resubscribe. Adds `PreferenceToken`
(HMAC-signed via `Phoenix.Token`), extends `CRMSource` and `DeliveryWorker`.

## Issues Found

### 1. [BUG - HIGH] Token verification, contact resolution, and a contact-creation WRITE all ran in `mount/3` — FIXED
**File:** `lib/phoenix_kit/newsletters/web/preference_center_live.ex` (pre-fix: lines 33-85)
**Confidence:** 92/100

`mount/3` called `resolve_access/2` directly — token verification, CRM
contact lookup, list resolution, and (on the account-nav path)
`CRMSource.find_or_link_contact_for_user/1`, which can **INSERT** a new
contact row and **UPDATE** it to link `user_uuid`. Since `mount/3` runs twice
per page load (disconnected HTTP render, then the connected websocket one):

- every read ran twice per visit (compounding finding #2's N+1 below), and
- the account-linking **write** happened during the plain disconnected HTTP
  GET, before any LiveView process was truly "connected."

The PR's own test acknowledged mount's double-invocation ("lazily creates and
links a contact on first visit, then reuses it on a later mount") and treated
idempotency-on-reuse as sufficient, but didn't address the architectural rule
or the doubled query/write cost.

**Fix applied:** `mount/3` now only sets `mode: :loading` plus the
`enabled?/0` gate (matching the `Newsletters.enabled?()` check every other
LiveView in this package does in `mount`). All token verification, contact
resolution, and the account-path's find-or-link write moved into a new
`handle_params/3`, guarded on `mode: :loading` so it only runs once per
navigation. Rewrote `preference_center_live_test.exs` to drive every test
through a `mount_and_resolve/3` helper that calls `mount` then `handle_params`
in sequence (mirroring the real LiveView lifecycle, where `handle_params`
always runs immediately after `mount` unless `mount` already redirected).

### 2. [BUG - MEDIUM] N+1 query in `load_lists/3` — not fixed (out of repo boundary)
**File:** `lib/phoenix_kit/newsletters/web/preference_center_live.ex:87-94` (now ~100-107)
**Confidence:** 75/100

`CRMSource.list_subscribable_lists/0` (1 query) is followed by
`CRMSource.subscribed?(contact, list)` once per list inside `Enum.map/2` (N
queries) — with finding #1 above, this was effectively doubled per page load.
`CRMSource.subscribed?/2` delegates to `PhoenixKitCRM.Lists.subscribed?/2`,
and the underlying `phoenix_kit_crm` dependency (a separate, published Hex
package) exposes no batched "which of these lists is this contact subscribed
to" query — verified by reading `deps/phoenix_kit_crm/lib/phoenix_kit_crm/lists.ex`'s
full public API. Adding one would mean changing a different repo, out of
scope here. Fixing finding #1 at least removes the doubling; the remaining
N+1 is bounded by the number of admin-configured subscribable lists (typically
small), so it's left as a documented follow-up rather than blocking.

### 3. [OBSERVATION] Benign race on concurrent double-mount can leave an orphaned unlinked contact
**File:** `lib/phoenix_kit/newsletters/crm_source.ex` (`find_or_create_contact_and_link/2`)
**Confidence:** 40/100

If two mounts for the same not-yet-linked user race, both could pass the
"no existing contact" check and each call `create_contact` before either
links; the loser's `link_contact_to_user` fails on the
`idx_crm_contacts_user_uuid` unique constraint and surfaces as a generic
`:error`, leaving an orphaned unlinked contact row. No security/duplicate-
linking issue. Not fixed — low priority, narrow window.

## What Was Done Well

- **`preference_token.ex`**: HMAC-signed via `Phoenix.Token`, its own salt
  (`"newsletters_preferences"`) deliberately distinct from the per-list
  unsubscribe salt, 7-day `max_age`, and every failure mode (malformed,
  expired, wrong salt) collapses into one `{:error, :invalid}` — verified
  against tests covering salt-crossing rejection and expiry.
- **No enumeration leak**: `resolve_access/2`'s `with`/`else` reaches
  `:invalid_token` uniformly whether the token is garbage, tampered, expired,
  or well-formed-but-names-a-nonexistent-contact.
- **`handle_event("toggle_list", ...)`** and the unsubscribe/resubscribe
  handlers never trust a client-supplied `list_uuid` beyond matching it
  against the server-resolved `socket.assigns.lists`/`contact` — correct
  discipline for a public, unauthenticated page.
- **`routes.ex`** is wired solely through `route_module/0`, no hand-registered
  route.
- **`find_or_link_contact_for_user/1`**: ambiguous-email case is deliberately
  treated as "no match" rather than guessing, avoiding silently placing an
  unrelated contact's list memberships under a user's control.
- Gettext: spot-checked ru/et `.po` for every new msgid — no fuzzy or empty
  entries.

## Verdict

**Approved with fixes** — the `mount/3` architectural violation (finding #1)
is fixed, closing both the doubled reads and, more importantly, the write
during a disconnected GET. Token verification and authorization-of-actions
were already solid with no data leak/replay/enumeration issues on this public
surface. The N+1 in `load_lists/3` (finding #2) remains, documented as a
follow-up that requires a change to the separate `phoenix_kit_crm` dependency.
