# Code Review: PR #19 — Show scheduled_at in the viewer's timezone (list + details)

**Reviewed:** 2026-07-22
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/19
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** b942689
**Status:** Merged

## Summary

Adds a shared `PhoenixKit.Newsletters.Web.Timezone` module (offset resolution +
display formatting) and wires it into `Broadcasts`, `BroadcastDetails`,
`BroadcastEditor`, and `ListMembers` so scheduled/sent times render in the
viewer's own timezone (profile → system setting → UTC) instead of raw UTC.

## Issues Found

### 1. [BUG - HIGH] `Timezone.user_tz_offset/1` called from `mount/3` in three LiveViews — FIXED
**File:** `lib/phoenix_kit/newsletters/web/broadcasts.ex` line 24, `lib/phoenix_kit/newsletters/web/broadcast_details.ex` line 30 (pre-fix); `lib/phoenix_kit/newsletters/web/list_members.ex` (now removed by PR #24)
**Confidence:** 95/100

`mount/3` runs twice per connection (disconnected HTTP render, then the
connected websocket one). `Timezone.user_tz_offset/1` — when the viewer has no
personal `user_timezone` set — falls through to `PhoenixKit.Utils.Date.get_user_timezone/1`,
which calls the **uncached** `Settings.get_setting/2` (a real DB query, verified
against `deps/phoenix_kit/lib/phoenix_kit/utils/date.ex:584-589` and
`deps/phoenix_kit/lib/phoenix_kit/settings/settings.ex:182-212`). That's a real
query fired twice per page load for a common case (no personal timezone set).

What makes this notable: the *same repo, same day*, commit `9aa6817` had just
fixed this exact anti-pattern in `BroadcastEditor` (moving tz resolution to
`handle_params`, with a comment explicitly explaining why). This PR reused that
fix correctly in `BroadcastEditor` (via the new shared `Timezone` module) but
introduced the same bug fresh into `Broadcasts` and `BroadcastDetails` (and,
at the time, `ListMembers`, since removed entirely by PR #24's legacy-list
cleanup).

**Fix applied:** moved `Timezone.user_tz_offset/1` + `tz_label/1` resolution
out of `mount/3` into `handle_params/3` in both `Broadcasts` and
`BroadcastDetails`, adding a private `assign_tz/1` helper matching
`BroadcastEditor`'s existing pattern exactly. Updated `broadcasts_test.exs`
and `broadcast_details_test.exs`'s timezone tests to exercise `handle_params`
instead of `mount` (which no longer resolves timezone at all).

### 2. [NITPICK] `Timezone`'s internal `user_tz_offset/1` mixes cached and uncached settings lookups
**File:** `lib/phoenix_kit/newsletters/web/timezone.ex:76-83`
**Confidence:** 70/100

The "no logged-in viewer" branch uses `Settings.get_setting_cached/2`, but the
"viewer has no personal timezone" branch goes through
`DateUtils.get_user_timezone/1`, which uses the uncached `Settings.get_setting/2`.
Moving the call site to `handle_params` (finding #1) bounds the damage to once
per navigation instead of twice, but the underlying inconsistency remains.
Not fixed — out of scope (would mean forking or wrapping core's
`get_user_timezone/1`), left as a follow-up note.

### 3. [OBSERVATION] Local `@time_zone_options` list duplicates a list core has since exposed a dedicated accessor for
**File:** `lib/phoenix_kit/newsletters/web/timezone.ex:13-49`
**Confidence:** 60/100

The moduledoc comment already flags this as deliberate ("core has no cheaper
dedicated accessor... a follow-up may add a cheaper core accessor"). Core
shipped `Settings.timezone_options/0`/`get_timezone_label/1` shortly after
(verified in `deps/phoenix_kit`, commit `89d811fd`). The duplication was
justified when written and is now removable, but that's a pure cleanup with no
behavioral bug — left as-is.

## What Was Done Well

- The shared `Timezone` module cleanly consolidates resolution logic that would
  otherwise drift across four LiveViews.
- `format_datetime/2` and `tz_label/1` are pure, nil-safe, and the fixed-offset
  (no real tz database, no DST) limitation is explicitly documented rather than
  silently assumed.
- Verified no business-logic-uses-local-time bug: `Newsletters.list_broadcasts/1`
  sorts/filters on the raw UTC `Ecto` fields; the new formatting helpers are
  strictly display-only and never feed back into comparisons.
- Core's `offset_to_seconds`/`get_timezone_label` degrade gracefully (fallback
  to `0`/`"UTC#{value}"`) for garbage/unknown timezone strings — no crash risk.
- `BroadcastEditor`'s own tz test correctly exercises `handle_params`, matching
  the intended architecture — it was only the other two views' tests that
  locked in the mount-based anti-pattern instead of catching it.

## Verdict

**Approved with fixes** — the mount-based DB query regression (finding #1) has
been fixed post-merge, moving all timezone resolution to `handle_params` for
every affected LiveView still in the codebase (`ListMembers` was independently
removed by PR #24). No other correctness issues found.
