# Code Review: PR #13 — Add full i18n for newsletters admin panel

**Reviewed:** 2026-11-05 (retrospective, against current `main`)
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/13
**Author:** Tymofii Shapovalov
**Status:** Merged (ab7d295)

## Summary

Wraps the admin LiveViews and templates in `gettext` on the module's own backend,
adds status label helpers, and ships en/et/ru catalogs. The list pages it touched
went with #24.

## Verification performed

- **The locale reaches this backend.** Core's `put_gettext_locale/2` sets the
  process-global locale, and always does for `PhoenixKit*` views, so
  `PhoenixKit.Newsletters.Gettext` reads it without its own `put_locale`.
- **Catalogs are complete.** et and ru had no empty `msgstr`.
- **Untranslated admin strings.** Pattern searches found no raw status in a
  template, no literal text node and no literal admin flash. The literal flashes
  they did find are the public ones below.

## Findings

### IMPROVEMENT - MEDIUM — Send now could flash a raw changeset — FIXED

`send_now/1` put `inspect(reason)` in a flash, so a rejected save read
`Failed to save: #Ecto.Changeset<action: :insert, changes: %{...`. The line
predates this PR, which wrapped it in `gettext` and so also gave translators a
dump to translate. Save draft and Schedule already rendered a sentence.

It is narrower than it looks: the button is disabled on `@subject == ""`, so a
truly empty subject cannot get there. A subject of spaces can (it fails
`validate_required`), and so can one over 998 characters (the input has no
`maxlength`).

Both paths now share `validation_error/1`. The new test in
`broadcast_editor_test.exs` failed before the fix. `reason` can only be a
changeset, since `create_broadcast/1` and `update_broadcast/2` are a plain
`Repo.insert` / `Repo.update`. The now-unused msgid left the catalogs (238 → 237).

### IMPROVEMENT - MEDIUM — Nothing ties status labels to the status lists — GUARDED

A status with no clause falls through to the raw lowercase value, so a new status
shows up untranslated without failing anything. `I18nTest` now checks every
`Broadcast.valid_statuses/0` on both broadcast pages and every
`Delivery.valid_statuses/0`. This guards behaviour that is correct today: the test
passed before any change, and fails when a clause is deleted (checked by removing
`"failed"` from `Broadcasts`).

### IMPROVEMENT - MEDIUM — The public unsubscribe flow is English only — NOT FIXED

`UnsubscribeController` has no `gettext` and both `unsubscribe_html` templates have
none, so a reader of a Russian or Estonian newsletter unsubscribes in English. The
preference center is translated.

Out of this PR's stated scope (the admin panel), and it is a feature rather than a
fix: a token visitor has no session locale, so the page needs a decision on where
the language comes from (`RecipientLanguage` from the token's subject is the
obvious candidate), plus reviewed translations for a compliance-sensitive page.

### NITPICK — Dead clauses in `BroadcastEditor.status_label/1` — NOT FIXED

It is one of three copies of this list and the only one without `"failed"`, but
`save_broadcast/3` is only ever called with `"draft"` or `"scheduled"`, so nothing
is missing in practice. Left alone: the guard above covers the two copies that
render stored statuses.

### NITPICK — `validation_error/1` does not interpolate — NOT FIXED

It maps errors with `fn {msg, _opts} -> msg end`, so by reading Ecto's message a
too-long subject shows `should be at most %{count} character(s)` literally. This
predates the PR and already applied to Save draft and Schedule. It is much better
than the changeset dump, so it was left as a separate change.

## Validation

The fixes from this review pass, checked together on the final tree:

- `mix precommit`: passed (compile with warnings as errors, unused-lock check, Hex
  audit, format, strict Credo, Dialyzer with its two existing ignored warnings).
- `mix test`: 726 tests, 0 failures, integration tests included, on a scratch
  database. The baseline before any change was 721 tests, 0 failures.
- `mix gettext.extract --check-up-to-date`: passed.
