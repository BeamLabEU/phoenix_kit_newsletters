# PR #42 review follow-up

Date: 2026-10-29. Reviewer: Codex.

| Finding | Resolution |
| --- | --- |
| Stale engine readiness on start | Recheck configured availability and enabled state before resolving an audience or calling the engine. |
| Delayed progress reopens terminal batches | Ignore further snapshots after the current batch becomes done or cancelled. |
| Pure bridge tests depend on PostgreSQL | Use `ExUnit.Case`; all 27 tests run with integration tests excluded. |

The four new regressions across #42/#43 failed before the fixes and pass
afterwards. The targeted suite passed: 166 tests, 0 failures. The full suite
passed: 717 tests, 0 failures, with PostgreSQL integration tests enabled on
the separate `phoenix_kit_newsletters_test_pr_review` database. The existing
test database was left unchanged because it is below core's migration floor.

`mix precommit` passed compilation with warnings as errors, unused-lock
checking, Hex audit, formatting, strict Credo and Dialyzer. Dialyzer retained
its two existing ignored warnings, with no additional warnings. The first
audit identified Bandit 1.14.0's security advisory; only Bandit was updated
in the lockfile, to 1.14.1, and the audit now passes.

`mix gettext.extract --check-up-to-date` and `git diff --check` passed.
Gettext catalog edits only refresh source line references. No version bump
or release was made.
