# Code Review: PR #36 — Standardise the admin header trail on the guide's shapes

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/36
**Author:** Max Don
**Status:** Merged (b8453ab)

## Summary

The list page titles itself "Newsletters"; new and details pages use
"Newsletters" as the section; the edit page is titled "Edit" with the broadcast
as a crumb linking to its details page. "Broadcasts" and "Edit broadcast" stay
in the catalogues as hand-listed tab labels.

## Verification performed

- "Edit" has `en`/`et`/`ru` translations (`Muuda` / `Редактировать`), so the
  new title is not an identity fallback in any shipped locale.
- `page_crumbs` is set on both editor paths (`[]` on new, one crumb on edit)
  and passed through `app_layout`, so the template assign never raises.
- The catalogue diff is line-reference churn plus the moved `Newsletters`
  entry; no msgid is lost (`Broadcasts` / `Edit broadcast` are still listed
  for the tabs).

## Findings

### 1. NITPICK — crumb label is the raw subject

`label: broadcast.subject` renders whatever the operator typed, including a
very long subject. The shared header truncates; no change here.

No bugs found.
