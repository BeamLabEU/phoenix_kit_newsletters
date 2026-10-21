# Code Review: PR #32 — Add a conformance test for the :phoenix_kit requirement

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/32
**Author:** Max Don
**Status:** Merged (4b10c3a)

## Summary

Adds `CorePinConformanceTest`: the `:phoenix_kit` requirement must admit every
core 2.x and nothing else, and a committed `path:` dep must fail the suite. It
reads the resolved dep first and falls back to the literal in `mix.exs`.

## Verification performed

- Ran the test against today's pin (`~> 2.52`). The file has since been moved
  to a 2.52 floor (`@must_admit`/`@must_reject` updated by PR #37), which is
  the intended maintenance path; the test passes.
- Walked the three-segment trap: `~> 2.52.1` fails the `2.99.4` and `2.52.0`
  expectations, so the test catches the mistake it was written for.
- Checked the `committed_requirement/0` regex against the only `:phoenix_kit,`
  literal in `mix.exs`: it cannot match `:phoenix_kit_crm` / `_templates`
  because the comma follows the atom immediately.

## Findings

### 1. NITPICK — comments describe a `pk_dep/3` / `PHOENIX_KIT_PATH` override this repo does not have

The comment above `core_requirement/0` says `pk_dep/3` rewrites the dep to a
`path:` tuple when `PHOENIX_KIT_PATH` is set. This module resolves core from
Hex (see AGENTS.md "Commands"); the override is a manual `mix.exs` edit. The
fallback to the committed literal is still right (a manual path edit hits the
same branch), only the explanation is stale.

**Not changed:** the code is correct and the comment is harmless; the test
file is shared in shape with sibling modules and diverging its prose here
would make later cross-module syncs noisier.

No bugs found.
