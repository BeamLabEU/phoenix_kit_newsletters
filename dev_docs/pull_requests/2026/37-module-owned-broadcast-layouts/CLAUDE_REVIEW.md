# Code Review: PR #37 — Add module-owned broadcast layouts with per-language rendering

**Reviewed:** 2026-10-04
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/37
**Author:** Tymofii Shapovalov
**Status:** Merged (f5c00a3)

## Summary

Moves operator-authored broadcast wrappers out of core's
`phoenix_kit_email_templates` into `phoenix_kit_newsletters_layouts`
(migration V2, `Layout`, `Layouts`), renders each email in the recipient's
language through a new `Render` (layout first, one `Substitution` pass,
core chrome from `Layout.render_parts/2`), adds the Layouts admin pages and a
per-language preview in the broadcast editor, and re-targets
`broadcasts.template_uuid` at the new table.

## Verification performed

- **V2 against core's source table.** `phoenix_kit_email_templates` (core V135)
  has every column the copy reads: `name`, `display_name`, `subject`,
  `html_body`, `text_body`, `category`, `status`, `metadata`, `is_system`,
  `created_by_user_uuid`. The `_<8 hex>` / `_<32 hex>` suffixes fit the
  `varchar(255)` name column (246 + 9, 222 + 33).
- **Settings read.** `phoenix_kit_settings.value` exists; the `EXECUTE` keeps a
  schema without the table from failing the migration.
- **Substitution semantics.** Read `PhoenixKit.Templates.Substitution` 0.2.2:
  `substitute/2` does not escape, so the subject pattern in `Render.subject/4`
  does not turn `Q&A` into `Q&amp;A`; the HTML pass uses `escape: true`.
- **Worker.** The cancel guards (`guard_broadcast_sendable/1`,
  `recheck_broadcast_sendable/1`) are untouched. The rendered subject reaches
  `send_email/7` through `%{broadcast | subject: subject}` and is not written
  back to the row.
- **LiveViews.** No query in `mount/3` in any new view; the preview iframe is
  `sandbox="allow-same-origin"` without `allow-scripts`; a preview language
  outside the offered list is ignored.
- **Suite.** `mix test`: 460 tests, 1 failure (finding 1).

## Findings

### BUG - MEDIUM — The suite is red on the current lock, and the core floor was left below the release it needs (fixed)

`mix.lock` is at `phoenix_kit` 2.52.1 (the `libs` commit after the merge).
Core 2.52 carries #896, so its `ExpectedSchema` manifest no longer declares
`fk_newsletters_broadcasts_template`. The test that compares V1's emitted
index/constraint operations with the manifest still expected V1's frozen guard
for that FK and failed:

```
unexpected: [{"DO", "fk_newsletters_broadcasts_template"}]
```

The PR's own notes say to raise the floor to the core release carrying #896
"when releasing". `~> 2.48` still admitted 2.48–2.51, where `doctor` reports
the re-targeted FK as wrong-shaped and `repair` exits non-zero on a host that
ran V2.

**Fix:** `{:phoenix_kit, "~> 2.52"}` (two-segment, as `CorePinConformanceTest`
requires). The pin test now admits 2.52.0+ and rejects 2.48.0 and 2.51.9. The
manifest comparison leaves V1's frozen FK guard out, with the reason beside
it, and a new test fails if a later core brings the FK back into the
manifest. The "Merge order" notes in `mix.exs`, the migrations moduledoc,
`AGENTS.md` and the README requirements table now describe the shipped state.

### IMPROVEMENT - MEDIUM — `AGENTS.md` still described the Emails soft dependency (fixed)

It said the module works without Emails installed because "template wrapping
is skipped", and told agents to guard `PhoenixKit.Modules.Emails.*`. Nothing
references that module any more; layouts are this package's table and the
standard layout is core's `PhoenixKit.Email.Layout`. Reworded. `required_modules/0`
is left at `["emails"]`; changing which modules core makes an operator enable
first is a product decision, not a review fix.

### NITPICK — `phoenix_kit_templates ~> 0.2.2` (not changed)

For a 0.x package that is the usual idiom, and the lock is on 0.2.2. It does
exclude a future 0.3, the same shape of trap `CorePinConformanceTest` guards
for core. Nothing here needs 0.2.2 specifically (`Substitution` with
`{{{…}}}` is 0.2.0), so the floor could be `~> 0.2` if 0.x minors turn out to
be compatible. Left for the maintainer.

### NITPICK — Subject pattern applies when the HTML fell back (not changed)

`Render.subject/4` picks the layout's subject pattern in the language its HTML
resolves to, even when that translation does not place `{{{content}}}` and
`Render.html/4` therefore sends the standard layout. A carried-over layout is
the only way to get there (untouched translations are not re-checked), and the
result is a standard-layout email under the layout's subject wrapper. Rare and
harmless; fixing it means `subject/4` re-running `wrapper/2`.

### NITPICK — Per-delivery reads (not changed)

Each job reads the layout row (both language maps) and, for a CRM recipient,
the list and its membership for the locale. Cheap next to an SMTP call, but a
50k send does 50k+ extra reads. Same trigger as the existing "bulk cancel"
TODO: do it when a send is large enough to show.

### NITPICK — `warn_once_without_content/2` keys grow per edit (not changed)

The `:persistent_term` key includes `updated_at`, so every re-save of a broken
layout adds a key that is never erased. Bounded by operator edits, so ignored.

### NITPICK — Layout editor keeps stale errors (not changed)

`errors` is only reset on the next save, so a fixed field keeps its message
until then. Cosmetic.
