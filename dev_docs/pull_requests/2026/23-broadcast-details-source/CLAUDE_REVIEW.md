# Code Review: PR #23 — Broadcast details: show recipient source (roles snapshot + stale-roles warning) for user_group broadcasts

**Reviewed:** 2026-07-22
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/23
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 4a48670
**Status:** Merged

## Summary

Follow-up to PR #22: the broadcast details page's recipient-source card
previously rendered blank for `source_type = "user_group"` broadcasts. This PR
renders the frozen `role_names_snapshot` (joined with a "Roles" badge) and a
stale-roles warning, reusing `UserGroupSource.preflight/1` (previously
editor-only) for the `stale_roles` count.

## Issues Found

### 1. [OBSERVATION] `preflight/1` reuse is heavier than the details page needs
**File:** `lib/phoenix_kit/newsletters/web/broadcast_details.ex:166-168`, `lib/phoenix_kit/newsletters/user_group_source.ex:108-123`
**Confidence:** 45/100

`preflight/1` has no side effects, so calling it from a read-only view is
safe. But to surface only `stale_roles`, it still runs the full
`users_for_role_uuids/1` join plus a batched CRM-contacts lookup and computes
sendable/no_email/unsendable in memory — none of which the details page uses.
For a broadly-assigned role, every view/refresh of a sent broadcast's details
page pays the full audience-resolution cost just to render a stale-count
badge. Not fixed — mirrors a pattern already accepted in the editor (which
recomputes the same full breakdown on every checkbox click); a cheap
dedicated `stale_role_count/1` would be a reasonable follow-up, not a blocker.

### 2. No bugs found in the stale-roles logic, the untouched source branches, gettext, or test coverage

Verified by reading the file as it stood at the merge commit (not just
current HEAD, which has since had the `newsletters_list` branch removed by
the unrelated PR #24):

- `stale_roles = length(Enum.uniq(role_uuids)) - existing_role_count(role_uuids)` —
  dedup applied before subtraction, no off-by-one/inversion; verified against
  both a live-role and a role-deleted-after-save scenario.
- The pre-existing `newsletters_list`/`crm_list` `cond` branches are
  byte-identical to their pre-PR state — only the new `user_group` branch was
  inserted ahead of them.
- The PR description's claim of "four wrong fuzzy merges" isn't fully
  traceable in the diff itself (only one fuzzy fix and one blank-`msgstr` fill
  are visible; no `"subscriber"` msgid exists anywhere in the repo to check
  against) — looks like a stale/inaccurate PR description carried over from
  intermediate rebase churn, not a live defect. The end state at HEAD has zero
  `#, fuzzy` flags in en/et/ru, and the reused msgid for the stale-roles
  warning reads sensibly in both the editor and details contexts.
- Test coverage matches all four scenarios asked for: nil preflight for both
  other source types, a live-role case, and a post-save-deleted-role case.

## What Was Done Well

- Clear in-code footnote on exactly which slice of `preflight/1`'s result is
  used and why.
- Correct, minimal reuse of `Broadcast.role_uuids/1`/`role_names_snapshot/1`.
- Gettext hygiene is clean — no fuzzy flags, no crossed translations between
  near-miss string pairs (Blocked/Bounced, Send to/Send now, etc).

## Verdict

**Approved.** No correctness bugs found; the one efficiency nitpick (finding
#1) is a follow-up candidate, not a blocker, and mirrors an already-accepted
pattern elsewhere in the codebase.
