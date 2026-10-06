# Code Review: PR #39 — Fix layout editor language tabs not matching stored translations

**Reviewed:** 2026-10-06
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/39
**Author:** Tymofii Shapovalov
**Status:** Merged (04c0843)

## Summary

The editor listed the site's languages plus every stored key, so a site spelling
languages with a dialect (`en-US`) over a layout storing base keys (`en`) got
duplicate tabs, opened on an empty one and saved a dialect key beside the base
key. `Layout.language_tabs/2` now yields one tab per site language, each
mapping every field to the stored key it reads and writes (exact, base, another
dialect, else a new key). A key belongs to one tab per field; unclaimed stored
keys get their own tabs; a subject stored under a key no HTML uses is shown on
a flagged "residue" tab. The subject is stored under the tab's HTML key, which
is where `Render.subject/4` reads it. The name field suggests a slug.

## Verification performed

- **Subject placement matches a send.** `Render.subject/4` picks the language
  with `Layout.translation_key(html, locale)` and reads the pattern at that
  key; the editor's subject key is the tab's HTML key, and `assign_preview`
  mirrors the same lookup.
- **One owner per key.** Walked `claim_keys/2` (exact, base, dialect passes in
  site order), `with_fallbacks/3` and `extra_tab/5`; a site language that
  stores its exact key always claims it, so an extra tab never shares a label
  with a site tab. The exhaustive ownership test in `layout_test.exs` pins this.
- **Save cannot lose data.** `apply_params/2` writes only keys the current tab
  owns and skips disabled (unsubmitted) fields; blank values are dropped by
  `Layout.changeset/2`'s `compact/1`, so clearing a field removes it.
- **No empty-tab crash.** `LanguageOptions.site_languages/0` is never empty
  (content language first), so the `[%{keys: ...} | _]` match for a new layout
  and `List.first(tabs)` hold. `with_languages/1`'s removal leaves no caller.
- `mix test` for the layout and web tests: 184 tests, 0 failures.

## Findings

No bugs found.

### 1. NITPICK — "has HTML" badge counted whitespace-only HTML

The tab badge used `not in [nil, ""]`, while the tab-opening logic and the
changeset treat whitespace-only text as blank, so a tab holding only spaces
showed the badge but was not a stored translation.

**Fixed:** a shared `filled?/2` in `LayoutEditor` (also used by `has_content?/2`)
drives the badge; a test types whitespace and then real HTML.

### 2. IMPROVEMENT - MEDIUM — gettext source references were out of date

`mix gettext.extract --merge --check-up-to-date` failed on `default.pot`: line
references had drifted after the last editor edit. Refreshed all catalogs (no
message changes).

### 3. NITPICK — CLAUDE.md architecture listing predated `language_tabs/2`

The `layout.ex` and `layout_editor.ex` lines did not mention the tab/key
mapping. Updated.

## Not changed

- `suggest_name/1` drops non-ASCII letters (`"Café"` → `caf`). The name rule is
  ASCII-only by design and the suggestion is only offered, never applied.
- The editor's `switch_language` does not re-apply form params; it relies on
  `validate` having stored every edit, which holds because LiveView flushes a
  debounced input on blur before the click event.
