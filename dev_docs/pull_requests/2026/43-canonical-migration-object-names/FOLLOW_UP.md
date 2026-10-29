# PR #43 review follow-up

Date: 2026-10-29. Reviewer: Codex.

| Finding | Resolution |
| --- | --- |
| Primary-key rename collides with another constraint | Check both the relation and constraint namespaces before renaming; retain the old name and warn on collision. |
| A different primary key receives the canonical name | Require the candidate's complete column list to be exactly UUID. |
| Invalid-index test requires superuser catalog writes | Build a real invalid index using a failed concurrent unique build in a separate scratch schema. |

Both new real-DDL regressions reproduced the incorrect behaviour before the
fixes. The original full-suite failure on `UPDATE pg_index` is also resolved
without granting extra privileges. Existing manifest/repair, OID-preservation,
idempotence and rollback tests pass.

Validation for the combined #42/#43 fixes:

- Targeted suite: 166 tests, 0 failures.
- Full suite: 717 tests, 0 failures, including PostgreSQL integration tests
  on the separate `phoenix_kit_newsletters_test_pr_review` database.
- `mix precommit`: passed compile with warnings as errors, unused-lock check,
  Hex audit, formatting, strict Credo and Dialyzer. Its two existing ignored
  Dialyzer warnings are unchanged.
- `mix gettext.extract --check-up-to-date` and `git diff --check`: passed.

The first audit required updating the locked Bandit from 1.14.0 to 1.14.1;
no other dependency was changed. The existing test database, V1/V2 snapshots,
schema manifest, package version and CHANGELOG were left unchanged.
