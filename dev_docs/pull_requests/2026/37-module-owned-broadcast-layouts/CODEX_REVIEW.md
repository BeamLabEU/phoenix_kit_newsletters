# Code Review: PR #37 — Module-owned broadcast layouts

Reviewed: 2026-10-04 by Codex.
PR: https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/37
Merged commit: `f5c00a3`; review baseline: `88255a6` plus Claude's uncommitted fixes.

## Findings and fixes

### BUG - HIGH — Layout-name collisions can abort migration V2

The bulk `INSERT ... SELECT` checks names only against the destination's
pre-statement state. A generated suffix can equal another source template's
name, and both rows then choose the same destination name. Also, the assumed
unique full-UUID suffix can already belong to an operator-created layout.
Both cases reproduce PostgreSQL `23505` and abort the upgrade.

The import now inserts rows in deterministic name/UUID order, checking the
destination after each insert. It tries the original name, eight UUID hex
digits, the full UUID, then numbered suffixes until free. Every generated
name fits `Layout.column_widths().name`. UUIDs, content, existing destination
rows, archived system-email handling, source rows and the import marker are
preserved. Three database regression tests cover same-import collisions,
an occupied full-UUID suffix, and maximum-length names.

V2 is introduced by this PR, after tag `0.3.0`; no local release tag contains
the PR. Its pre-release SQL snapshot was updated to include the corrected
import. V1's published SQL snapshot remains unchanged. This does not change
the database shape or require another core manifest change.

### BUG - MEDIUM — Invalid translation values silently disappear

`compact/1` discarded every non-string value before validating translation
maps. An invalid language entry could therefore be accepted while removing
that translation. Compaction now removes only blank strings and leaves
malformed entries for validation to reject. Regression coverage exercises
all four translatable fields with numbers, booleans, nulls, maps and lists.

### BUG - MEDIUM — Subject fallback and newline handling are inconsistent

A layout with missing or unusable HTML could still apply its subject pattern,
including a subject in a language whose HTML was not sent. Subject rendering
now uses a pattern only when the selected HTML translation places the body.
All subject paths remove CR/LF, including the no-layout path. Tests cover
empty HTML maps, legacy wrappers without content, and unwrapped subjects.

### IMPROVEMENT - MEDIUM — Warning-cache entries grow on every layout edit

The warning cache formerly allocated a permanent key for every layout
version and requested locale. It now keeps one key per layout, replacing the
remembered version and tracking resolved translation keys. Different reader
dialects falling back to the same HTML share one warning. Content participates
in the version, so two edits within one timestamp second can warn again.
Regression coverage checks warning suppression, subsequent edits, and key
count. Concurrent first renders can still duplicate a warning, as before;
warning suppression does not affect delivery behavior.

### IMPROVEMENT - MEDIUM — Save errors remain after fields are corrected

After a failed save, form changes now revalidate the current fields. Corrected
errors disappear while outstanding errors stay visible. Validation remains
quiet before the first failed save. A callback test covers partial and complete
corrections.

## Claude's changes

Retained and checked the two-segment `phoenix_kit ~> 2.52` floor, the matching
pin test and documentation, and the manifest regression test. The locked core
2.52.1 no longer declares the FK that V2 retargets. Claude's original
`mix precommit` log ended with `EXIT=0`.

Kept `phoenix_kit_templates ~> 0.2.2`: broadening a 0.x dependency to an
unreviewed minor is not required for this fix. Kept per-delivery database reads:
caching layouts and membership introduces freshness and invalidation policy,
and the existing design reflects changes made during a throttled send.

## Validation

The new regressions initially reproduced five failures: two migration name
collisions, malformed translation acceptance, subject fallback, and CR/LF
handling. Final full-suite and precommit results are recorded in `FOLLOW_UP.md`.
