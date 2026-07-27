# Code Review: PR #28 — Broadcast attachments: media picker + DeliveryWorker + details view

**Reviewed:** 2026-07-27
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/28
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 905c14bd83a306ad6a84e85236f1b1332ff0a5c9
**Merge SHA:** cdc0f2853115d43d67331d3c886af58dcf83f2aa
**Status:** Merged

## Summary

Adds file attachments to broadcasts end to end:

1. **Schema** — `Broadcast.attachments`, an ordered list of core Storage file
   uuids (core V158 adds the backing `jsonb` column). `changeset/2` dedups
   (first occurrence wins, so order is preserved), caps at 10, and rejects
   anything that isn't a uuid.
2. **Editor** — a `MediaSelectorModal` picker in `:multiple` mode, removable
   chips showing filename + size, a non-blocking warning over 7 MB total, and
   a "missing file" ghost chip for a uuid that no longer resolves.
3. **DeliveryWorker** — resolves each uuid to a `%Swoosh.Attachment{}` right
   before the send, attaches on both the profile-routed and legacy paths,
   skips (and logs) any file it can't read rather than failing the whole
   broadcast, and caches downloads across jobs so a 10k-recipient send
   doesn't re-download the same file 10k times.
4. **Details** — a read-only chip list mirroring the editor's.
5. **Tests** — changeset cases, an editor case for the unresolvable uuid, and
   worker tests that store real bytes through a local-provider bucket and
   read them back (no mocking). A new `:requires_v158` ExUnit tag, probed via
   an `information_schema` query rather than a version string, gates the
   tests that need the new column.

The feature itself is right, and the care taken over the parts that usually
go wrong here is visible: attachments resolve *after* rendering so a job that
fails earlier never pays for a download; a broken attachment degrades instead
of blocking delivery; the temp file is removed on both branches; the temp
path uses crypto-random bytes; the picker sits outside the broadcast `<form>`
so its inner submit button can't submit the broadcast. Two of those came out
of an earlier review round on the branch, and it shows.

The defect is in the one piece of shared mutable state the PR introduces.

## Issues Found

### 1. [BUG - HIGH] The cross-job attachment cache is owned by an Oban job process — it dies with the first job, and racing jobs crash on it — FIXED

**File:** `lib/phoenix_kit/newsletters/workers/delivery_worker.ex` lines 432–479 (as merged)
**Confidence:** 100/100

The cache was a named public ETS table created lazily from inside
`perform/1`:

```elixir
defp ensure_attachment_cache_table! do
  :ets.new(@attachment_cache_table, [:set, :public, :named_table, read_concurrency: true])
rescue
  ArgumentError -> :ok
end
```

An ETS table is owned by the process that created it and is **destroyed when
that process exits**. Oban runs every job in a fresh, short-lived process, so
the owner here is whichever delivery job happened to touch the cache first —
and it exits as soon as that one email is sent. Two consequences:

* **The cache does not survive a single job.** Its entire stated purpose is
  cross-job reuse ("the same file uuid is downloaded once and reused by every
  delivery job for the rest of a broadcast's send"). Within one job the
  uuid list is already deduped, so the cache saves nothing there. In
  production every recipient re-downloaded every attachment — the exact
  behaviour the cache was added (in `20f3ad8`, as review MAJOR-1) to prevent.
* **Concurrent jobs crash.** `cached_attachment/1` calls
  `ensure_attachment_cache_table!()` and *then* `:ets.lookup/2`. If the owner
  exits in between, the lookup raises `ArgumentError` and the delivery job
  fails. `cache_attachment/2` has the same window on `:ets.insert/2`. With
  the default 14/sec rate limit and concurrent workers, that window is open
  continuously for the whole of any broadcast carrying attachments.

Verified directly — a spawned process creates a named public table and
exits; `:ets.whereis/1` then returns `:undefined` and `:ets.lookup/2` raises
`ArgumentError`.

The tests couldn't catch either half: they call `build_attachment/2` twice
from the *same* (test) process, which owns the table for the duration.

**Fix applied.** Extracted the cache into
`PhoenixKit.Newsletters.AttachmentCache`, a GenServer that owns the table for
the lifetime of the application, plus a minimal
`PhoenixKit.Newsletters.Application` declared as the package's `:mod` in
`mix.exs`. This is the first process the package has ever owned; the
alternative (rescuing `ArgumentError` at every call site) would have removed
the crash while leaving the cache permanently non-functional, which is half a
fix.

Reads and writes still go straight to ETS — the table stays `:public`, so
concurrent workers on different keys never contend and nothing queues behind
the GenServer. It only owns the table and sweeps it. Every operation still
degrades to a cache miss if the table isn't there, so a host that somehow
runs the modules without the application started still delivers mail.

New tests in `test/phoenix_kit/newsletters/attachment_cache_test.exs` lock in
the property that actually failed: an entry written by a process that then
*exits* is still readable afterwards.

### 2. [BUG - MEDIUM] Cached attachments were evicted only on read, so a finished broadcast's file bytes stayed resident indefinitely — FIXED

**File:** `lib/phoenix_kit/newsletters/workers/delivery_worker.ex` lines 457–472 (as merged)
**Confidence:** 90/100

Expiry was lazy: an entry was dropped only when something looked it up again
and found it stale. But the access pattern here is exactly the one lazy
eviction cannot handle — once a broadcast finishes sending, nobody ever looks
up its attachments again, so its entries were never the subject of a read and
never evicted. Each held the file's full bytes in memory (`data:`, not
`path:` — a deliberate and correct choice for other reasons). Ten 7 MB
attachments per broadcast, retained for the life of the node, accumulating
per broadcast.

The original comment argued "no reaper process needed for a cache this size",
which was reasonable *given* no process was available to run one. Now that
`AttachmentCache` owns the table, one is.

**Fix applied.** `AttachmentCache` sweeps expired entries every minute via a
single `:ets.select_delete/2`. Lazy eviction on read is kept as well — it's
free and it keeps a stale entry from being served in the window before a
sweep. Memory is now bounded by "attachments used in the last two minutes"
rather than "every attachment ever sent". Covered by a sweep test.

### 3. [IMPROVEMENT - MEDIUM] The media picker didn't enforce the 10-attachment cap the changeset rejects on — FIXED

**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.html.heex` lines 320–332 (as merged)
**Confidence:** 95/100

`Broadcast.changeset/2` caps attachments at 10, but the picker was rendered
without a cap, so a user could select 15 files, confirm, see 15 chips, fill
in the rest of the broadcast, hit save — and only then get
`Validation failed: attachments: should have at most 10 item(s)` in a flash,
with no indication of which five to remove.

Core's `MediaSelectorModal` has an attr for exactly this — `max_select`,
which stops selection at the cap and renders both an `N / max` counter and a
"Maximum N files" notice. Its own docs give the rationale: *"MediaGallery
passes its max_count so users can't select past the limit only to have the
gallery silently truncate on confirm."* This is the same situation, one list
(the picker's cap) that has to stay in sync with another (the changeset's).

**Fix applied.** Exposed the cap as `Broadcast.max_attachments/0` — a single
source of truth rather than a second literal `10` in the template — and
passed it as `max_select`. A test asserts `max_attachments/0` *is* the number
the changeset enforces, so the two can't drift.

### 4. [IMPROVEMENT - MEDIUM] The media picker was passed an untracked assign, re-running its `update/2` query on every keystroke — FIXED

**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.html.heex` line 331
**Confidence:** 80/100

The picker was mounted with:

```heex
phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
```

LiveView's change tracking is driven by `@assign` references the compiler can
see; the `assigns[...]` access form is opaque to it, so the expression is
treated as changed on every render. That marks the component's assigns as
changed, which re-runs `MediaSelectorModal.update/2` — and the first thing
`update/2` does is `Storage.list_enabled_buckets()`, an uncached
`SELECT ... FROM ... WHERE enabled = true`.

The broadcast form is `phx-change="validate"`, so the parent re-renders on
every keystroke in the subject and the Markdown body. That makes this a
buckets query per keystroke, whether or not the picker is even open. The same
class of defect as the duplicate CRM `get_list` queries fixed in 0.1.11, and
new with this PR — the component didn't exist here before.

`assigns[:phoenix_kit_current_user]` is a common idiom in core's own pages,
which is presumably where it was copied from; it's harmless there because
those pages aren't keystroke-driven forms.

**Fix applied.** `mount/3` now does
`assign_new(:phoenix_kit_current_user, fn -> nil end)` — which keeps the
value PhoenixKit's admin `on_mount` hook supplies and only fills a default if
it's absent — so the template can use the tracked `@phoenix_kit_current_user`
without risking an `ArgumentError` on a socket that never got the hook. With
every attribute passed to the component now tracked, a keystroke that changes
only the body leaves the picker's subtree untouched.

Rated 80 rather than higher because the query-per-keystroke claim rests on
LiveView's documented change-tracking behaviour rather than on a measured
query count (this environment has no test database). The fix is safe either
way: it strictly narrows when the component re-renders, and `assign_new`
cannot clobber the hook's value.

Deliberately *not* done: wrapping the component in `:if={@show_media_selector}`
so it isn't mounted while closed. That would be a bigger saving, but the modal
renders a `<dialog>` driven by a `phx-hook="PkDialog"` reading `data-show`,
and unmounting the element rather than toggling that attribute changes the
open/close path in ways this package shouldn't be deciding for core's
component.

### 5. [NITPICK] `BroadcastDetails` didn't guard `attachments` against `nil` where the editor did — FIXED

**File:** `lib/phoenix_kit/newsletters/web/broadcast_details.ex` line 156
**Confidence:** 70/100

`BroadcastEditor` reads `broadcast.attachments || []`; `BroadcastDetails`
passed `broadcast.attachments` straight into `load_attachment_files/1`, whose
non-empty clause calls `Storage.get_files/1` — which is `when is_list(uuids)`
and would raise `FunctionClauseError` on `nil`.

Not currently reachable: V158 declares the column `NOT NULL DEFAULT
'[]'::jsonb`, so it can't be `nil` from the database. Fixed anyway for the
cost of three characters, because the asymmetry reads as though one of the
two call sites knows something the other doesn't.

### 6. [OBSERVATION] Stale `mix.exs` dependency comments — FIXED

The `phoenix_kit` dep carried two accumulated comments stating that V151 and
V158 were "unreleased"/"not yet in a hex release", that hex was "currently
1.7.210", and that a path or git override was required. All of that is now
false — the floor was already bumped to `>= 1.7.211` on the branch (`6aa0d14`)
and the lockfile sits at 1.7.213. Replaced with a note on what the floor
actually encodes (a migration floor: V151's send-profile context and V158's
`attachments` column) and when to raise it.

The constraint itself (`~> 1.7 and >= 1.7.211`) is left as is: the `>=` here
tracks a hard runtime requirement — an older core compiles fine and then
fails on a missing column — rather than tightening for its own sake.

## What Was Done Well

* **Resolution placement.** Attachments resolve inside the `with` chain
  *after* delivery/recipient lookup and rendering, so a job that fails an
  earlier step never downloads anything. The comment says so, and the code
  matches.
* **Degrade, don't block.** One unreadable attachment out of ten is logged
  and dropped; the other nine still reach every recipient. There's a test for
  the partial case, not just the happy one.
* **`data:` over `path:`, with the reasoning recorded.** The comment works
  through why a shared temp file would need reference-counted or reaper-based
  cleanup once a cached entry outlives a single send. That reasoning is what
  made issue #1 findable — it's precisely correct *about* the multi-job
  lifetime, which is what exposed that the cache didn't have one.
* **Ghost chips.** `Storage.get_files/1` silently drops uuids with no row;
  zipping back against the full uuid list keeps every entry visible, so a
  deleted file can still be *removed* instead of becoming an invisible
  attachment nobody can clear. Both LiveViews do it, and there's a test.
* **The `:requires_v158` tag is probed, not assumed.** An
  `information_schema` query rather than a version-string comparison, so it
  stays correct when run against a local core whose version string predates
  the migration. Its own tag rather than folding into `:integration`, so it
  excludes only what actually needs the column.
* **Storage tests use real bytes.** A local-provider bucket in a temp dir,
  actual `store_file/2` → `retrieve_file/2` round trips, and an explicit
  `:persistent_term.erase/1` of core's bucket cache with a comment explaining
  why the Ecto sandbox doesn't cover it.
* **The picker is outside the `<form>`**, with a comment explaining that its
  internal search button would otherwise submit the broadcast.
* **No queries in `mount/3`.** Both LiveViews load in the `handle_params`
  path.

## Verdict

**Approved with fixes.** The feature is well built and the failure modes that
matter for email — partial attachment failure, temp-file leakage, form
hijacking, invisible stale references — were all handled deliberately. The
one thing that didn't work was the cross-job cache: correct in intent, but
parked in an ETS table owned by a process that exits after one job, which
both defeated the caching and put an `ArgumentError` race on the delivery
path. That's now a supervised, swept cache with a regression test covering
owner death. The picker cap and the `nil` guard are small consistency fixes.
