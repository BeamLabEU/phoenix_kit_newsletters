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

### IMPROVEMENT - MEDIUM — The public unsubscribe flow was English only — FIXED

`UnsubscribeController` and both `unsubscribe_html` templates had no `gettext`, so
a reader of a Russian or Estonian newsletter unsubscribed in English. Out of this
PR's stated scope, and first left open for a decision on the language source.

Every response is now in the language of the email the link came from:
`RecipientLanguage.for_contact/2` (contact, then list, then site) for CRM tokens
and `preferred_locale` for role tokens. Rendering runs inside
`RecipientLocale.in_locale/2`, because a keep-alive connection reuses the process
and a plain `put_locale` would leak one recipient's language into the next
request. Both modules name this package's backend after core's `use`, which binds
core's; without that the strings compile and silently stay English. A test
mutation confirmed both of these are caught.

The preference center had the same gap for token visitors. Its token names no
list, and a LiveView process outlives a callback, so it overrides core's mount only
for a contact's own stated language, and sets the locale on the process.

The list name lost its bold, since a translated sentence cannot carry markup
safely without `raw`. The et and ru strings were written here and follow the
existing catalogs' terms, but have had no native review.

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
