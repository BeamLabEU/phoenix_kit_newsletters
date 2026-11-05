# Code Review: PR #6 — Fix token keys, catch-all, README, tests and icon

**Reviewed:** 2026-11-05 (retrospective, against current `main`)
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/6
**Author:** Tymofii Shapovalov
**Status:** Merged (dbbb71c)

## Summary

Corrects the README's token payload to a map, adds a `process_unsubscribe/2`
catch-all that flashes and redirects instead of raising on a malformed POST,
changes the module icon from `hero-megaphone` to `📨`, and loosens the test
that required a `hero-` prefix.

## Verification performed

- **The icon is the only change that looked wrong, and is not.** `Core.Icon`
  renders only `hero-*` names and silently renders nothing otherwise, so an
  emoji looked like a blank icon. But the value reaches the page through
  `ModuleCard.module_card/1`, which branches on `String.starts_with?(@icon,
  "hero-")` and prints anything else as text. `📨` displays correctly.
  `Permissions.module_icon/1` also returns this value, but no web module in core
  3.3 calls it, and core's permission matrix renders no module icon.
- **Loosened test is justified** for the same reason: core accepts both forms.
  The sibling `phoenix_kit_emails` module uses an emoji too.
- **Catch-all still exists:** `unsubscribe_controller.ex:133`.
- **README:** the token section has since been rewritten for three salts.

## Findings

None.

### NITPICK — `module_icon/1` documents a Heroicon name

Core's `@doc` says it returns a Heroicon name, which an emoji is not. It has no
rendering caller today, so nothing is affected. Not changed: the doc is core's,
and switching the icon here would be churn for no visible difference.
