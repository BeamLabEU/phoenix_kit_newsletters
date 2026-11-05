# Code Review: PR #9 — Add css_sources/0, fix Emails soft dependency compile warnings

**Reviewed:** 2026-11-05 (retrospective, against current `main`)
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/9
**Author:** Max Don
**Status:** Merged (20ac630)

## Summary

Adds `css_sources/0`, and replaces aliases of the optional Emails module with
module attributes and `apply/3` to silence compile warnings.

## Verification performed

- `css_sources/0` still returns `[:phoenix_kit_newsletters]`
  (`newsletters.ex:276`), matching AGENTS.md.
- The Emails soft-dependency code this PR rewrote no longer exists. #37 moved
  layouts into this package, so the `@email_template*_mod` attributes and the
  `get_translation(_, "en")` calls are gone. That hardcoded `"en"` would break
  today's "never hardcode `en`" rule, but it did not survive.

## Findings

None that still apply.
