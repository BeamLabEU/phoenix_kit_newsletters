# Code Review: PR #26 — Fix role wipe on Send now/Schedule and SMTP-receipt crash causing duplicate sends

**Reviewed:** 2026-07-24
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/26
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 874c06d
**Status:** Merged

## Summary

Three fixes bundled into one branch:

1. **Role wipe on Send now / Schedule** (`broadcast_editor.ex`,
   `broadcast_editor.html.heex`) — "Send now" and "Schedule" were
   `type="button"` + `phx-click`, which submits no form data at all. Since
   `resolve_role_uuids/2` is deliberately params-authoritative (an unchecked
   checkbox never appears in `params`, so it can't fall back to the old
   assign without breaking "uncheck a role"), every `user_group` send via
   those two buttons saw `role_uuids: []` and failed changeset validation
   with "select at least one role". Fix: single `phx-submit="submit"` on the
   form, all three actions are now `type="submit"` buttons distinguished by
   `name="action" value="..."`, and a new `handle_event("submit", ...)`
   dispatches on `params["action"]`. A submitted form always carries the
   full serialized state, checkboxes included.
2. **SMTP receipt crash** (`delivery_worker.ex`) — `Map.get(result, :id)`
   assumed every Swoosh adapter's `{:ok, result}` is a map. Real API
   adapters (SES, Brevo) do return a map with `:id`, but
   `Swoosh.Adapters.SMTP` returns the raw server receipt as a **string**
   (e.g. `"2.0.0 OK: queued as <abc@host>\r\n"`), so `Map.get/2` raised
   `BadMapError` — *after* the SMTP server had already accepted the message.
   Oban then retried the whole job on the `BadMapError`, resending the same
   email up to `max_attempts` times while the delivery row stayed `pending`
   forever. Fix: `extract_message_id/1` branches on `is_map`/`is_binary`,
   regexing an id out of the SMTP receipt string and falling back to `nil`
   (never raising) for anything unrecognized.
3. **Wrapper-template variable-substitution ordering** (`delivery_worker.ex`,
   commit 874c06d) — variables were substituted into the broadcast body
   *before* wrapping it in the `{{content}}` email template, so any variable
   the wrapper itself referenced (notably an `{{unsubscribe_url}}` footer
   link) was never substituted and shipped as a literal tag in the sent
   email. Fix: `compose_html/3` merges body into wrapper first, then runs
   substitution once over the combined string.

Also included: `broadcast_details_test.exs` swaps fixture `"some-uuid"` for
`Ecto.UUID.generate()` — the batched CRM preflight query added in #25 now
casts `role_uuids` and raises `Ecto.Query.CastError` on a non-UUID string.

## Issues Found

None. Specifically checked and confirmed correct:

- **The submitter-carries-form-data claim is real, not assumed.** Verified
  against `deps/phoenix_live_view/priv/static/phoenix_live_view.cjs.js`
  (LiveView 1.2.7, this repo's resolved version): `submitForm`/`pushFormSubmit`
  read `e.submitter` off the native `SubmitEvent`, and `serializeForm`
  injects a hidden `submitter.name`/`submitter.value` pair into the
  serialized payload before it's pushed. A `type="submit" name="action"
  value="send_now"` button genuinely round-trips `action=send_now` in
  `handle_event("submit", params, socket)`'s params — the fix's core
  mechanism isn't cargo-culted.
- **Implicit-submit (Enter key) behavior unchanged.** With three
  `type="submit"` buttons in one form, a keyboard Enter (no explicit
  submitter) uses the browser's default — the *first* submit button in
  document order, which is "Save draft". That matches the pre-PR default
  (`phx-submit="save_draft"` on the form itself), so this isn't a new way to
  accidentally trigger a real send via Enter.
- **No stale `phx-click="send_now"`/`"schedule"` wiring left behind** —
  grepped `lib/` for both; only the new submit-button paths exist.
  `attempt`/`max_attempts` on `Broadcaster`/`update_assigns_from_params`
  flow are unaffected by the dispatch change (`handle_event("submit", ...)`
  just calls the existing three handlers directly with the same params/
  socket it received).
- **`compose_html/3` ordering fix doesn't introduce double-substitution.**
  Previously: substitute body vars, *then* wrap (wrapper vars never
  substituted — the bug). Now: merge raw body into wrapper via one
  `String.replace(wrapper, "{{content}}", body)`, *then* substitute once
  over the combined string. Body-side `{{tags}}` still resolve exactly
  once; the fix only adds resolution for wrapper-side tags, it doesn't
  change how body-side tags resolve.
- **`extract_message_id/1` is fail-safe by construction.** Three clauses
  (`is_map`, `is_binary`, catch-all) cover every term shape Swoosh could
  return in `{:ok, result}`; none of them can raise, which is the actual
  point — a message that reached the SMTP server is a delivered send
  regardless of whether an id could be parsed back out of the receipt text.
  Confirmed the regex (`~r/queued as\s+<?([^>\s\r\n]+)>?/i`) against both the
  angle-bracket and bare-token receipt shapes in the added tests, and that
  an unrecognized string (`"250 OK"`) correctly falls through to `nil`
  rather than matching garbage.
- **`template_html/1` split from `compose_html/3` cleanly** — fetching the
  wrapper HTML (guarded by the existing `Code.ensure_loaded?` soft-dependency
  check, returns `nil` on no template/missing row/module not loaded) is now
  fully separate from the substitution-ordering logic, and the fetch-side
  guard behavior is unchanged from the pre-PR `maybe_apply_template/2`.
- **Test regressions are actual regression pins, not just coverage padding**
  — `broadcast_editor_test.exs`'s new "submit routing" tests call
  `handle_event("submit", ...)` directly and assert `role_uuids` survives
  with the submitted value, which is exactly the wipe this PR fixes (a test
  written against the old code would have failed here). Same for
  `compose_html/3`'s wrapper-ordering test and `extract_message_id/1`'s
  per-shape tests.
- **`broadcast_details_test.exs`'s uuid fixture fix is warranted, not
  incidental** — `create_user_group_broadcast/2`'s `role_uuids` now flow
  into a batched CRM contacts query (added in #25) that casts them as
  UUIDs; `"some-uuid"` would raise `Ecto.Query.CastError` in that query
  before it ever got to timezone resolution behavior these tests exist to
  check.

## What Was Done Well

- Root-caused all three bugs to their actual mechanism (LiveView's
  `phx-click` carrying no form data; Swoosh's adapter-dependent return
  shape; substitution/wrap ordering) rather than patching symptoms.
- Every fix ships with a test that specifically pins the regression being
  fixed, not just incidental coverage.
- `extract_message_id/1` and `compose_html/3` were deliberately made
  public+`@doc false` (not `defp`) so the fix is unit-testable without
  needing a live SMTP adapter or the optional `Emails.Template` dependency
  loaded — consistent with this module's existing pattern for other
  internal seams (`resolve_send_profile/1`, `build_profile_email/5`).
- In-code comments explain *why*, including the exact prior failure
  mode (`BadMapError` after the provider already accepted the message,
  wiped roles from a `phx-click` event) — useful for anyone hitting this
  file again without this PR's context.

## Verdict

**Approved.** No issues found; fixes are correctly root-caused, minimal,
and each is locked in by a test that would have failed against the
pre-PR code.
