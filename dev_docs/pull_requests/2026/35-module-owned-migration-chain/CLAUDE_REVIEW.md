# Code Review: PR #35 — Add module-owned migration chain for the 2 newsletters tables

**Reviewed:** 2026-09-17
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/35
**Author:** Tymofii Shapovalov
**Status:** Merged (9cf9687)

## Summary

Adds `PhoenixKitNewsletters.Migrations` and wires it through
`migration_module/0`, so `mix phoenix_kit.update` now generates a host
migration that runs this module's V1. V1 is a pure adoption: `CREATE TABLE IF
NOT EXISTS` with the full current shape of both tables, a guarded PK, the two
CHECKs, eleven indexes and four FKs, then a `pknl_schema:1` comment on
`phoenix_kit_newsletters_broadcasts`. `down/1` only touches the comment.

The guards match by shape (`pg_constraint`/`pg_index` through `::regclass`)
instead of by name. A real host had renamed the tables from
`phoenix_kit_mailing_*`, and a name-based PK guard crashed there. Also adds
`column_widths/0` to both schemas and rewrites the README, which still
described the removed `List`/`ListMember` model.

## Verification performed

- **Core floor.** Pulled `phoenix_kit` 2.0.0 from Hex. Everything the chain
  calls is there: `Helpers.qualify_table/2`, `uuid_v7_call/1`,
  `validate_prefix!/1`, `ensure_extension!/1`, `ensure_uuid_v7_function/1`,
  `PhoenixKit.RepoHelper`, `PhoenixKit.Migrations.Modules` and the
  `migration_module/0` callback. The `~> 2.0` pin does not need to move.
- **Host call shape.** `mix phoenix_kit.update` writes
  `Mod.up(prefix: "<prefix>", version: target)` /
  `Mod.down(prefix: "<prefix>", version: installed)`. `with_defaults/2`
  handles both the keyword list and a string prefix.
- **Manifest agreement.** Spot-checked `ExpectedSchema` (core 2.28.1). For
  example, `subject` is `character varying(998)` with `not_null: true` in
  `revisions` (the manifest's `create` text leaves out NOT NULL; the DDL
  follows `revisions`, which is correct). The column-by-column test in
  `migrations_test.exs` covers the rest.
- **Existing installs.** For an existing table, `CREATE TABLE IF NOT EXISTS`
  returns before Postgres resolves column types, so the literal
  `public.citext` cannot break an install that already has the table.
- **Tests.** Full suite with the DB up: 355 tests, 0 failures. The 40
  migration tests include real `Ecto.Migration.Runner` runs against a
  renamed-host fixture and an expression-index fixture.

## Findings

### IMPROVEMENT - MEDIUM — Customer host project named in published moduledoc — FIXED

The `@moduledoc` ("Guards are semantic, not name-based") named a specific
customer host application and the timestamp of its private migration. The
moduledoc ships to HexDocs, so a client project's name would be published.
Changed it to "a real host's own `rename_mailing_to_newsletters` migration".
The technical explanation is unchanged. The test moduledoc
(`migrations_renamed_host_test.exs`) still names the host, but tests are not in
the Hex package, so it was left alone.

### NITPICK — `index_guard` escaped its predicate in one place but not the other — FIXED

The comment says a predicate is caller-supplied text and must have its single
quotes doubled. The code did that for the `EXECUTE '...'` argument, but the
`pg_get_expr(i.indpred, i.indrelid) = '<predicate>'` comparison above it used
the raw predicate. None of today's predicates contain a quote, so the SQL
output is byte-identical (the frozen-statements test still passes). A future
predicate like `status <> 'failed'` would have ended the literal early. Both
places now escape it, and the comment covers both.

### NITPICK — AGENTS.md drift — FIXED

- The "What this module does NOT do" list opened with "Owns its two tables'
  future shape…", which is a positive claim in a negative list. Reworded it to
  "Does not yet create its own tables. It owns their future shape…".
- Added `migrations.ex` to the Architecture tree.
- The Testing section now says `test_helper.exs` also runs this chain's
  `up_statements/0`, and lists `migrations_test.exs` under "Runs without
  Postgres" (the other `migrations_*_test.exs` files need the DB).
- README's module table listed the chain as `Migrations`, but every other row
  there is relative to `PhoenixKit.Newsletters` and the real name is
  `PhoenixKitNewsletters.Migrations`. It now uses the full name.

### NITPICK — `recipient_email public.citext` on a fresh non-`public` install — NOT FIXED

On a Phase 2 fresh install whose connection role has a `search_path` that puts
`citext` somewhere other than `public`, the literal `public.citext` would not
resolve. A bare `citext` would have the reverse problem when `public` is not
on the `search_path`. On every install this project supports today the
extension is in `public`, and existing installs never reach type resolution
(see above). The moduledoc already explains the choice. Left as is.

### NITPICK — Moduledoc length — NOT FIXED

The moduledoc runs to roughly 245 lines, and much of it is investigation
narrative ("a dedicated research pass…", "an independent second review…").
That belongs in the commit history more than in HexDocs. It is accurate and
the sibling chains use the same style, so it was not trimmed in a post-merge
fix.

### Observation — legacy index shape on renamed hosts

On a host whose legacy `idx_mailing_*` indexes differ in shape from V135's
(for example, a non-unique `message_id` index from before the squash), the
shape guard will not match and V1 will build the canonical index next to the
legacy one. For the unique `message_id` index, the build fails if duplicate
non-null `message_id`s exist. The PR verified the one renamed host it knows
about, and this failure would be loud rather than silent, so no guard was
added. Recording it in case another renamed host turns up.

## Gate

`mix format` + `mix precommit` (compile --warnings-as-errors, format, credo
--strict, dialyzer, deps.unlock --check-unused, hex.audit) passed.
`mix test`: 355 tests, 0 failures. Released as 0.3.0.
