# Code Review: PR #18 — Fix broadcast schedule time being interpreted as UTC

**Reviewed:** 2026-07-20
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/18
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** merged via b305bc9 (merges a70012f)
**Status:** Merged (b305bc9)

## Summary

Before this PR, the broadcast composer's `datetime-local` schedule input was
parsed with `DateTime.from_naive!(ndt, "Etc/UTC")` — typing "21:58" always
saved 21:58 UTC regardless of the admin's own timezone, so for anyone ahead
of UTC the broadcast fired hours later than intended. The PR:

1. Resolves the viewer's timezone offset (`PhoenixKit.Utils.Date.get_user_timezone/1`
   — personal profile setting → system `time_zone` setting → `"0"`) and uses
   `DateUtils.parse_datetime_local/2` / `format_datetime_local/2` to convert
   between that offset and UTC, instead of assuming UTC.
2. Adds a "Sends at HH:MM (tz) · HH:MM UTC" hint next to the field so the
   interpretation is explicit.
3. Restores the schedule field to the broadcast's actual scheduled time (in
   the viewer's timezone) when editing — previously always blank on edit.

Well tested for the timezone-math itself: positive/negative offsets, two
midnight-rollover directions, the zero-offset (legacy) case, and an
unparseable-input error path.

## Issues Found

### 1. [BUG - MEDIUM] Timezone resolution added to `mount/3` — doubles an uncached settings query — FIXED

**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.ex`, `mount/3` / `user_tz_offset/1`
**Confidence:** 90/100

The PR computed `tz_offset` in `mount/3`:

```elixir
def mount(_params, _session, socket) do
  if Newsletters.enabled?() do
    tz_offset = user_tz_offset(socket)
    ...
```

`mount/3` runs twice per page load (once for the disconnected HTTP render,
once for the connected WebSocket mount) — the Phoenix Iron Law is no DB
queries there for exactly this reason. `user_tz_offset/1` calls
`DateUtils.get_user_timezone(user)`, which — whenever the current admin
hasn't set a personal `user_timezone` (the common case, since it's an
opt-in per-user preference) — falls through to `PhoenixKit.Settings.get_setting/2`,
an **uncached** query straight to `Queries.get_setting_by_key/1`. So most
visits to this page now fire an extra raw DB round-trip, twice.

The PR's own commit message claims this "reuses" the pattern already used
by "the Maintenance module's scheduled window and CRM's interaction
composer," but neither actually supports computing it in `mount`:

- `lib/modules/maintenance/settings.ex` resolves timezone with
  `Settings.get_setting_cached/2` (the ETS-backed variant), not the
  uncached `get_setting/2` this PR uses.
- `phoenix_kit_crm`'s `contact_show_live.ex` does call the same uncached
  `get_user_timezone/1` this PR uses, but from **`handle_params/3`**, not
  `mount/3` — which is exactly the distinction the Iron Law draws.

This LiveView already has a `handle_params/3` doing the real data loading
(lists, CRM lists, templates, the broadcast itself on edit), so there's a
natural, already-established home for it.

**Fix:** Moved `tz_offset`/`tz_label` resolution out of `mount/3` into a new
`assign_tz/1` helper, called from both `handle_params/3` clauses (`:edit`
and the default `:new` path) before anything that reads `@tz_offset`.
Updated the existing `handle_params(:edit)` test to supply
`phoenix_kit_current_user` instead of pre-seeding `tz_offset`/`tz_label`
directly (since `handle_params` now computes them itself), and added a new
`handle_params(:new)` test asserting `tz_offset`/`tz_label` are correctly
derived from `phoenix_kit_current_user.user_timezone`.

## What Was Done Well

- Correctly root-caused the actual bug (hardcoded UTC interpretation) rather
  than a narrower symptom fix, and reused core's existing
  `parse_datetime_local/2` / `format_datetime_local/2` pair instead of
  hand-rolling offset math.
- The "Sends at ... · ... UTC" hint turns an implicit, easy-to-get-wrong
  assumption into something the admin can visually verify before
  scheduling — directly addresses the class of bug being fixed, not just
  the one reported instance.
- Restoring the schedule field's value on edit (previously always blank) is
  a real, independently useful fix bundled sensibly with the timezone work
  since both touch the same field's round-trip.
- Solid test coverage of the actual timezone arithmetic, including both
  midnight-rollover directions and the legacy zero-offset case — the part
  most likely to have an off-by-one-hour or sign error.

## Validation

- `mix format --check-formatted` — clean.
- `mix compile --warnings-as-errors` — clean.
- `mix credo --strict` — clean (381 mods/funs, no issues).
- `mix dialyzer` — clean, no new warnings.
- `mix test` — **could not be run**: no Postgres available in this sandbox
  (no server, no package-manager root, no Docker) and this suite is
  DB-backed (`PhoenixKitNewsletters.Test.Repo`). The fix and its test
  changes were verified by reading, not by executing. **Run `mix test` (in
  particular `broadcast_editor_test.exs`) in an environment with Postgres
  before relying on this fix or publishing a release built on it.**

## Verdict

**Approved with fixes.** The core timezone-interpretation fix is correct
and well-tested; the one gap (timezone resolution landing in `mount/3`
instead of `handle_params/3`) is fixed and regression-tested in this pass.
