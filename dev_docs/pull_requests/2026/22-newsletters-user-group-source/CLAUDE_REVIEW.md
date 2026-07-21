# Code Review: PR #22 — Newsletters: user_group (core roles) recipient source

**Reviewed:** 2026-07-21
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/22
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 962a4814c2a01766a6852de2654135ee28a93d00
**Status:** Merged (merge commit 3885f8a)

## Summary

Adds a third broadcast recipient source, `user_group`, targeting core `Roles`/`RoleAssignment`
users directly (no CRM dependency required). Touches `Broadcast` (new `source_params` map,
resolved by role **uuid** not name), `Broadcaster` (resolve/count/enqueue clauses for the new
source, plus a `stream_active_members/1` fix so `newsletters_list` sends also exclude
deactivated users), `UserGroupSource` (new module: sendable-recipient resolution, preflight
breakdown, opt-out), `BroadcastEditor` (role multi-select UI), `DeliveryWorker` /
`UnsubscribeController` (a dedicated, separately-salted unsubscribe token flavor for
role-sourced recipients, since the existing list-flavor token silently no-ops for them).

The branch already carried its own delta-review pass before merge (3 follow-up commits fixing
a non-functional unsubscribe link, an inactive-user inconsistency between sources, and
opt-out-failure logging/token-salt tagging), and the code is unusually well-documented — most
non-obvious decisions (uuid vs name resolution, salt-tagging to keep token claim shapes from
overlapping, dedup-by-user vs dedup-by-address) are explained inline. Verified the reasoning
in those comments against the actual dependency code (`phoenix_kit`/`phoenix_kit_crm` are
vendored under `deps/` in this workspace) rather than taking them at face value; all checked
out. Test coverage is thorough, including adversarial "cross-flavor token" tests for the salt
tagging.

## Issues Found

### 1. [BUG - MEDIUM] `mount/3` queries roles directly, doubling the query on every editor load — FIXED
**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.ex` (was line 46; now split across
lines 46, 84, 116)
**Confidence:** 95/100

`mount/3` assigned `:available_roles` via `UserGroupSource.list_roles()` — a real
`Repo.all/1` query (`PhoenixKit.Users.Roles.list_roles/0`). LiveView's `mount/3` runs twice per
page load (the disconnected HTTP render, then the connected WebSocket mount), so this doubled
the roles query on every visit to the broadcast editor — the exact anti-pattern this module's
sibling sources were written to avoid: `@lists` and `@crm_lists` are both deliberately assigned
`[]` in `mount` and only populated in `handle_params` (see the existing comments there). The
new `@available_roles` assign didn't follow that same pattern.

Not a correctness bug — the roles list still renders correctly either way — but a real,
easily-avoidable doubled DB round trip on a page that already loads on every visit to the
broadcast editor (new or edit).

**Fix applied:** moved `UserGroupSource.list_roles()` out of `mount/3` (now assigns `[]` there,
matching `@lists`/`@crm_lists`) and into both `handle_params/3` clauses (`:edit` and the
new-broadcast default), exactly mirroring how `lists`/`crm_lists` are already loaded.

### 2. [IMPROVEMENT - MEDIUM] New user-facing strings never extracted to the gettext catalog — FIXED
**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.html.heex`, `priv/gettext/**`
**Confidence:** 90/100

The editor template wraps three new/changed strings in `gettext`/`ngettext` —
`"Roles"`, the `%{total} users: ...` preflight line (renamed from `%{total} members: ...`),
and the `%{count} selected role(s) no longer exist(s)` plural — but `priv/gettext/default.pot`
and the `en`/`et`/`ru` `.po` files were never regenerated. `mix gettext.extract
--check-up-to-date` fails on the merged tree. This project treats full translation (not just
extraction) as part of landing a PR — every other user-facing string in this file already has
real Estonian/Russian text, not just an English mirror — so the gap would have shipped an
untranslated "Roles" radio option and a broken/blank preflight line for et/ru admins.

**Fix applied:** ran `mix gettext.extract --merge`, then filled in the three new msgids for all
three locales (English mirrors the msgid per existing convention; Estonian/Russian follow the
noun choice and plural patterns already used by the neighboring `"%{count} active subscriber"`
/ `"Added %{count} user to the list"` entries — `kasutaja(t)`/`пользователь` for "user", not the
`liige`/`участник` ("member") used by the list-based preflight text). `mix gettext.extract
--check-up-to-date` now passes. Left one unrelated pre-existing fuzzy entry
(`"Scheduled at"` → `"Scheduled"`, from PR #19) untouched — out of scope for this PR and not
something to guess a fix for without a translator's input.

## What Was Done Well

- **Uuid-based resolution, not name-based.** `Broadcast.role_uuids/1` / `source_params` store
  role uuids with a display-only name snapshot, specifically because `Roles.update_role/2`
  doesn't protect a role's name (verified against `deps/phoenix_kit`) — a name-keyed broadcast
  would silently re-target or empty out on a rename. Backed by dedicated rename/delete-resilience
  tests in `user_group_source_test.exs`.
- **Token salt-tagging.** The role-sourced unsubscribe token is signed under a distinct salt
  (`"newsletters_user_optout"`, not `"unsubscribe"`) specifically because its claim shape
  (`%{user_uuid:}`) is a subset of the list flavor's (`%{user_uuid:, list_uuid:}`) — pattern
  matching alone couldn't keep the two from colliding. `verify_token/1` tags a match by *which
  salt* verified (`{:role_optout, _}` vs `{:ok, _}`), making the safety property independent of
  clause order. `role_optout_unsubscribe_test.exs` has explicit adversarial tests posting a
  flavor-A token against the role-flavor endpoint and vice versa.
- **Cross-source consistency fix folded in.** `stream_active_members/1` (the `newsletters_list`
  send path) picked up the same `is_active` join filter `UserGroupSource.sendable?/1` already
  applied, closing a gap where a deactivated user with a stale "active" `ListMember` row would
  receive a `newsletters_list` broadcast but not a `user_group` one. `count_sendable_members/1`
  mirrors the same filter so the pre-send `total_recipients` estimate stays accurate.
- **Opt-out writes both applicable places without overreaching.** `record_opt_out/1` always
  writes the user's own `custom_fields`, and additionally opts out a *linked* CRM contact when
  one already exists — never creates one. A failure on the (best-effort) contact side is logged
  but doesn't fail the call, since the role-sourced opt-out itself already succeeded.
- Test coverage is unusually thorough for a first cut: dedup-across-roles, stale/deleted/renamed
  role uuids, deactivated users, opted-out-via-contact vs opted-out-via-custom-field, idempotent
  re-opt-out, and the cross-flavor token rejection tests noted above.

## Verdict

**Approved with fixes.** Both issues found were fixed in this pass (a doubled-query `mount/3`
regression, and an untranslated-strings gap); neither blocks the merge that already happened,
but both are worth landing before another editor round-trip ships with them. `mix precommit`
(compile --warnings-as-errors, credo --strict, dialyzer) and `mix gettext.extract
--check-up-to-date` both pass clean. `mix test` passes (101 tests, 0 failures) for everything
not requiring a live Postgres connection — this sandbox has no DB available, so the ~152
DB-backed tests added/touched by this PR (including all of `user_group_source_test.exs`,
`broadcaster_user_group_test.exs`, `broadcaster_inactive_user_test.exs`, and
`role_optout_unsubscribe_test.exs`) could not be executed here; they were read in full and
verified by hand against `deps/phoenix_kit`/`deps/phoenix_kit_crm`'s actual function
signatures.
