# Code Review: PR #14 — Add PhoenixKit.SchemaPrefix for runtime named-schema (--prefix) support

**Reviewed:** 2026-11-05 (retrospective, against current `main`)
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/14
**Author:** Max Don
**Status:** Merged (db8baae)

## Summary

Adds `use PhoenixKit.SchemaPrefix` to the table-backed schemas, raises the core
pin, and adds `SchemaPrefixConformanceTest`.

## Verification performed

- **Every current table-backed schema has it:** `Broadcast`, `Delivery` and
  `Layout`. `List` and `ListMember` went with #24.
- **Nothing bypasses the schema's prefix.** No `Repo.query` or other raw SQL in
  `lib/` outside `migrations.ex`, and no string-source `from x in "table"`
  queries. `insert_all` in the broadcaster goes through the `Delivery` schema.
- **The conformance test's text match is sufficient.** It looks for
  `schema "phoenix_kit` without `use PhoenixKit.SchemaPrefix`, and every table
  here carries that name.

## Findings

None that still apply.

### NITPICK — three-segment core pin (superseded)

`~> 1.7.189` admits only 1.7.x, which AGENTS.md now forbids. The range has since
been replaced by `>= 2.65.0 and < 4.0.0` and is guarded by
`CorePinConformanceTest`, so there is nothing to change.
