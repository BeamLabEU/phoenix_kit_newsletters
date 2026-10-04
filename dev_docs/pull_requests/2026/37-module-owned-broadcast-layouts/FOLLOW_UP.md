# PR #37 review follow-up

Date: 2026-10-04.

| Review finding | Resolution |
| --- | --- |
| Claude: core floor and manifest mismatch | Retained `~> 2.52`, pin coverage, manifest regression and documentation corrections. |
| Claude: obsolete Emails layout documentation | Retained documentation corrections. |
| Claude: subject pattern survives HTML fallback | Fixed; subjects now follow usable HTML translation selection. |
| Claude: warning keys accumulate per edit | Fixed; one cache key per layout remembers its latest version and resolved translations. |
| Claude: stale layout-editor errors | Fixed; changes after a failed save refresh errors. |
| Claude: templates dependency range | Kept the 0.2.x range; no compatibility evidence for future 0.3. |
| Claude: per-delivery reads | Kept current freshness semantics; no cache invalidation policy added. |
| Codex: migration import collisions | Fixed with sequential name allocation and bounded-width numbered suffixes; database regression tests added. |
| Codex: malformed translation acceptance | Fixed by preserving invalid values for validation; regression coverage added. |
| Codex: CR/LF on unwrapped subjects | Fixed by cleaning every subject path; regression coverage added. |

Validation:

- `mix test`: **468 tests, 0 failures**, including PostgreSQL integration
  tests and the real-DDL migration tests; no integration exclusions.
- `mix precommit`: passed compile with warnings as errors, unused-lock check,
  Hex audit, formatting check, strict Credo and Dialyzer. Dialyzer's two
  existing Gettext opaque-type warnings remain covered by the unchanged
  ignore file; no new warnings.
- `git diff --check`: passed.

The original regression run had five failures on the previous implementation.
Claude's own gate was also confirmed complete with exit status 0.
