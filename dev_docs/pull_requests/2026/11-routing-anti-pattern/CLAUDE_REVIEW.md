# Code Review: PR #11 — Add routing anti-pattern pointer to AGENTS.md

**Reviewed:** 2026-11-05 (retrospective, against current `main`)
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/11
**Author:** Max Don
**Status:** Merged (e686245)

## Summary

One line in AGENTS.md: never hand-register this module's routes in a host
router, with a pointer to core's `guides/custom-admin-pages.md`.

## Verification performed

- The rule survives in today's AGENTS.md ("Web conventions"), and the code
  follows it: admin routes come from `admin_tabs/0`, public ones from
  `route_module/0`.
- The guide exists in the core repo (`phoenix_kit/guides/custom-admin-pages.md`).

## Findings

None.

### NITPICK — the guide is not in the Hex package

`deps/phoenix_kit/` has no `guides/` directory, so the pointer only resolves with
a core checkout next to this repo. Not changed: "core's guide" is still the right
reference, and core decides what it packages.
