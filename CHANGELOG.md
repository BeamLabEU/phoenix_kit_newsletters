# Changelog

## 0.1.13 - 2026-07-31

### Added
- A broadcast that failed terminally — the only cause today is a scheduled send whose CRM list was archived — can be sent again from its details page once the cause is fixed. `Broadcaster.send/1` accepts `"failed"` alongside `"draft"`/`"scheduled"` and re-runs the same recipient-source validation, so a retry against a still-archived list fails the same way and the broadcast stays `"failed"`.

### Fixed
- The retry re-reads the broadcast before sending. It previously sent the copy the page loaded, so a click from a tab left open since the broadcast was retried elsewhere passed a stale `"failed"` status through `Broadcaster.send/1`'s guard — dragging an already-sending (or already-sent) broadcast back into `"sending"`, overwriting `sent_at`, and mailing anyone added to the audience in the meantime. A refusal now also refreshes the page, so the operator ends up looking at the broadcast's real status.
- "Send now" in the broadcast editor renders `Broadcaster.send/1`'s refusals as sentences instead of raw Elixir tuples, matching the details page. Both now share `Web.SendError.message/1`, so the two surfaces can't drift.
- The retry button, its confirmation, and the send-error messages are translated. They shipped as untranslated `gettext` calls missing from every catalogue, so Estonian and Russian operators saw raw English with nothing to flag it; `"Edit send profile"` was likewise blank in the `en` catalogue. The i18n test now fails on any msgid that is in `default.pot` but missing — or untranslated — in a locale.

### Added
- Broadcasts can now carry file attachments. The editor gets a media picker (core Storage), removable chips showing each file's name and size, a non-blocking warning once the attachments total more than 7 MB, and a visible "missing file" chip for a file deleted from Storage after it was attached — so a stale reference can still be removed rather than silently riding along. Up to 10 distinct files per broadcast, attached in the order they were picked; the broadcast details page shows the same list read-only. Requires core `>= 1.7.211` (V158).
- `DeliveryWorker` attaches those files to every delivery, on both the send-profile and legacy paths. A file that can't be read (deleted row, missing `original` variant, object unreachable in every bucket) is logged and skipped rather than failing the send — a broadcast with nine good attachments and one broken one still reaches every recipient with the nine.

### Fixed
- Attachment downloads are now genuinely shared across a broadcast's delivery jobs. The cache backing them was an ETS table created inside `perform/1`, so it was owned by whichever Oban job touched it first and was destroyed the moment that job finished — every recipient re-downloaded every attachment, and a job whose `:ets.lookup` landed just after the owner exited crashed with `ArgumentError`. The table is now owned by a supervised process (`PhoenixKit.Newsletters.AttachmentCache`, started by the package's new application module) for the lifetime of the node.
- Cached attachments are swept on a timer instead of only when something reads them again. Nothing re-reads a finished broadcast's attachments, so their bytes previously stayed resident for the life of the node; memory is now bounded by what was actually sent in the last two minutes.
- The editor's media picker now enforces the same 10-file cap the changeset does (`Broadcast.max_attachments/0`), instead of letting a larger selection through to fail as a validation error at save time.
- `DeliveryWorker` message-id extraction now matches Amazon SES over SMTP receipts. The pattern added in 0.1.11 was anchored on a literal `250 `, which `gen_smtp` strips before returning the receipt (`{ok, <<"250 ", Receipt/binary>>} -> Receipt`), so it never matched a real send and SES message ids were silently dropped. Receipts that do still carry the status code keep working.

## 0.1.11 - 2026-07-25

### Changed
- The broadcast editor's CRM list picker now offers only `subscribable` lists. Operational CRM segments (suppliers, imports, internal groupings) are no longer selectable as broadcast targets. The flag gates new selection only — a broadcast already pointing at such a list still resolves it for display and sending.

### Fixed
- A CRM list that fell out of the picker's options (archived, or `subscribable` turned off after the broadcast picked it) left the browser selecting the placeholder, so the next save silently reset `crm_list_uuid` and the broadcast lost its audience with no warning. The current selection now stays visible as a disabled "(no longer selectable)" option.
- `DeliveryWorker` message-id extraction now recognises Exim (`250 OK id=<id>`) and Amazon SES over SMTP (`250 Ok <MessageID>`) receipts alongside the Postfix-family `queued as` form; an unrecognised receipt still degrades to a `nil` message id rather than raising.
- Variable substitution in delivered emails is now a single pass over the whole body. Previously each `{{key}}` was replaced in its own pass, so a variable *value* containing a literal `{{other_key}}` — a crafted username, say — was itself expanded by a later pass. An unknown `{{tag}}` still renders literally.
- The broadcast editor issued two identical CRM `get_list` queries on every keystroke in the editor form (the archived-list warning and the stranded-selection fallback each resolved the same uuid independently); both now share one fetch.
- `CRMSource.list_lists/0` and `list_subscribable_lists/0` had become byte-identical duplicate queries with different callers; `list_lists/0` now delegates, so the filter can't drift between the broadcast picker and the preference center.

## 0.1.10 - 2026-07-24

### Fixed
- "Send now" and "Schedule" in the broadcast editor were `phx-click` buttons carrying no form data, so the params-authoritative role checkbox resolution wiped `role_uuids` to `[]` on every click — failing every `user_group` send with "select at least one role". Both are now `type="submit"` buttons routed through a single `phx-submit`, so the full form (role checkboxes included) always reaches the handler.
- `DeliveryWorker` crashed with `BadMapError` extracting the provider message id when the resolved send profile routed through `Swoosh.Adapters.SMTP`, which returns the server's raw receipt as a string rather than a map — after the SMTP server had already accepted the message. Oban then retried the whole job, resending the same email up to `max_attempts` times. Message-id extraction now handles both the map shape (API adapters) and the SMTP receipt string, and never raises.
- The broadcast's `{{content}}` wrapper email template had its own variables (notably the `{{unsubscribe_url}}` footer link) substituted before the body was wrapped into it, so template-side tags shipped as literal text in the sent email. Variable substitution now runs once, after the body is merged into the wrapper.

## 0.1.9 - 2026-07-22

### Removed
- The legacy list system (companion to core V156, which migrated every legacy newsletters list into CRM and dropped `phoenix_kit_newsletters_lists`, `..._list_members`, and `broadcasts.list_uuid`): the list management admin UI, the `newsletters_list` broadcast source end to end (editor, `Broadcaster`, `DeliveryWorker`, `UnsubscribeController`), and the `List`/`ListMember` schemas. Requires core `>= 1.7.207` (V156); an already-delivered legacy unsubscribe link still resolves to a friendly "invalid or expired" page instead of a crash.

### Added
- The broadcast details page now shows the recipient source for `user_group` (role-sourced) broadcasts too — the frozen role-names snapshot with a "Roles" badge, plus a stale-roles warning when a targeted role has since been deleted. Previously this card rendered blank for role-sourced broadcasts.

### Fixed
- `UserGroupSource.sendable_recipients/1` and `preflight/1` (the latter recomputed on every role-checkbox click in the broadcast editor) now issue one batched CRM contacts query instead of one query per resolved user.
- `Broadcasts`, `BroadcastDetails`, and `PreferenceCenterLive` resolved viewer timezone/contact state from `mount/3` instead of `handle_params/3` — since `mount/3` runs twice per connection (disconnected + connected render), this doubled an uncached settings query in the first two, and in `PreferenceCenterLive` could run the account-linking CRM contact write during a disconnected GET. All three now resolve in `handle_params/3`, matching the existing pattern in `BroadcastEditor`.

## 0.1.8 - 2026-07-21

### Added
- New `user_group` broadcast recipient source — target core users by role (`PhoenixKit.Users.Roles`/`RoleAssignment`) directly, without requiring the CRM module. The broadcast editor gains a "Roles" multi-select alongside "Newsletter list"/"CRM list", with the same sendable/no-email/unsendable preflight breakdown as the other sources.
- A dedicated unsubscribe/opt-out flow for role-sourced recipients: a separately-salted one-click token, a confirm/already-unsubscribed/unsubscribed landing page, and `UserGroupSource.record_opt_out/1`, which writes the user's own opt-out state and (when linked) the corresponding CRM contact's, keeping both consistent.

### Fixed
- A role-sourced (`user_group`) delivery's unsubscribe link previously reused the `newsletters_list` token shape with a `nil` list_uuid, so it verified but silently opted nobody out; it now signs its own token flavor.
- `newsletters_list` sends now exclude deactivated (`is_active: false`) users, matching what `user_group` already excluded — previously a deactivated user with a stale "active" `ListMember` row still received `newsletters_list` broadcasts.
- The broadcast editor's role list is now loaded in `handle_params/3` instead of `mount/3`, avoiding a doubled roles query on every visit to the page (`mount/3` runs once for the disconnected render, once for the connected one) — matches how the newsletter/CRM list options were already loaded.
- The new "Roles" recipient-source UI strings (role picker label, preflight summary, stale-role warning) are now fully translated (en/et/ru); they had shipped without gettext extraction.

## 0.1.7 - 2026-07-20

### Fixed
- The broadcast composer's schedule field now interprets the typed time in the viewer's own timezone (personal profile setting, falling back to the system `time_zone` setting) instead of always assuming UTC — previously scheduling "21:58" always meant 21:58 UTC, firing hours later than intended for anyone ahead of UTC. A "Sends at HH:MM (tz) · HH:MM UTC" hint next to the field makes the interpretation explicit.
- The schedule field is now restored to the broadcast's actual scheduled time (in the viewer's timezone) when editing a scheduled broadcast — previously it was always blank, with no way to verify what was scheduled without retyping it.
- Timezone resolution for the schedule field moved from `mount/3` to `handle_params/3`, avoiding an uncached settings query firing twice per page load (once for the disconnected render, once for the connected one).

## 0.1.6 - 2026-07-19

### Fixed
- `process_scheduled_broadcasts/0` no longer retries a scheduled broadcast against an archived CRM list forever — `Broadcaster.send/1`'s `{:crm_list_not_active, _}` error now transitions the broadcast to a new terminal `"failed"` status instead of leaving it `"scheduled"` for every future scheduler tick to re-fetch and re-fail.
- `Delivery.changeset/2`'s `unique_constraint(:message_id)` now names the constraint after the real DB index (`idx_newsletters_deliveries_message_id`, from core migration V79) instead of Ecto's default naming convention, so a genuine unique violation returns `{:error, changeset}` instead of raising `Ecto.ConstraintError`.
- List-Unsubscribe / List-Unsubscribe-Post headers (RFC 8058) are now added for `newsletters_list` (user) broadcasts too, not just `crm_list` broadcasts — the one-click POST endpoint's controller clause was also extended to handle the `user_uuid`/`list_uuid` token shape, which previously fell through to a silent no-op.
- Added the missing `"failed"` option to the broadcasts admin page's status filter dropdown, so broadcasts that hit the new terminal failed state can be filtered to in the UI.

## 0.1.5 - 2026-07-13

### Security
- Replaced Earmark (retired, `EEF-CVE-2026-48591` — stored XSS via unescaped HTML attribute values) with MDEx for markdown-to-HTML rendering in `Content.render_markdown/1` and `render_markdown_strict/1`. Output now also runs through `PhoenixKit.Utils.HtmlSanitizer.sanitize/1` — newsletter HTML goes out to every list member by email, not just a trusted-admin preview, so it's sanitized unconditionally.

### Changed
- `earmark` dependency replaced with `mdex ~> 0.13` (matches `phoenix_kit` core and `phoenix_kit_publishing`), plus an optional `rustler` pin so the transitive `mdex_native` NIF can source-build on hosts whose precompiled variant doesn't match.
- `render_markdown_strict/1`'s error branch now returns `{:error, reason}` (an `MDEx.DecodeError`/`MDEx.InvalidInputError` struct) instead of Earmark's list of error tuples; no in-repo caller pattern-matched the previous shape.

### Fixed
- Loosened the `phoenix_kit` dependency back to `~> 1.7 and >= 1.7.189` — a prior commit had tightened it to `~> 1.7.189`, which caps consumers below `1.8.0`; the floor-with-open-ceiling form keeps the runtime schema-prefix requirement without blocking future minor releases.
- Added `.dialyzer_ignore.exs` (and wired it into `mix.exs`) for the known upstream `Gettext.Backend`/`Expo.PluralForms` `call_without_opaque` false positive, matching every other `phoenix_kit_*` package — `mix precommit` was failing dialyzer without it.

## 0.1.4 - 2026-05-25

### Added
- Full i18n coverage for the entire newsletters admin panel. Every admin LiveView (Broadcasts, Broadcast Editor, Broadcast Details, Lists, List Editor, List Members) and template now wraps user-facing strings — labels, buttons, table headers, filters, flash messages, status/delivery badges and confirm dialogs — in `gettext`/`ngettext`, backed by `PhoenixKit.Newsletters.Gettext`.
- Complete `en`/`ru`/`et` translations for all new msgids, including plural forms (`nplurals=3` for `ru`, `nplurals=2` for `et`) for the subscriber and "added users" counters.

### Changed
- Normalized all multi-word admin labels (page titles, nav tab labels, buttons, dialogs) on sentence case for consistency: `New broadcast`, `Edit broadcast`, `Broadcast details`, `New list`, `Edit list`, `List members`, `Newsletter lists`.
- Hardened the `precommit` alias to `compile --force --warnings-as-errors`, `deps.unlock --check-unused`, and `quality.ci`; refreshed dependency lockfile.

## 0.1.3 - 2026-05-09

### Added
- Per-module Gettext backend (`PhoenixKit.Newsletters.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` ≥ 1.7.106 (ships the `gettext_backend` Tab API); older releases render tabs as raw English (graceful degradation).
- Drift-guard test in `i18n_test.exs` asserting every admin tab label has a non-identity ru translation — fails loudly when a new tab is added without updating `priv/gettext/`.

### Changed
- i18n test suite runs `async: true` (Gettext locale is per-process, no shared state).
- Simplified `test/test_helper.exs` to one-line `ExUnit.start()` now that `phoenix_kit` 1.7.106 (with the `gettext_backend` API) is published on Hex.

## 0.1.2 - 2026-04-11

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.1.1 (2026-04-02)

### Improvements

- Migrate select elements to daisyUI 5 label wrapper pattern
- Fix compile warnings for optional Emails dependency
- Add `css_sources/0` for Tailwind CSS scanning of component styles

### Fixes

- Fix remaining code review issues (token keys, catch-all handlers, strip_html)
- Extract `Content` module for better separation of concerns
- Add fallback clause to `UnsubscribeController` for missing token
- Fix duplicate admin route and UUID validation in ListMembers
- Move DB queries from `mount/3` to `handle_params/3` (LiveView best practice)

## 0.1.0 (2026-03-17)

Initial release of PhoenixKit Newsletters as a standalone Hex package, extracted from the PhoenixKit monolith.

### Features

- **Mailing lists** — create and manage newsletter lists with name, slug, and status
- **Broadcasts** — compose emails in Markdown with live preview, save as draft, schedule, or send immediately
- **Batch delivery** — Oban-based pipeline streams list members in batches of 500, creates per-recipient Delivery records, and enqueues individual DeliveryWorker jobs
- **Variable substitution** — `{{name}}`, `{{email}}`, `{{unsubscribe_url}}` replaced per recipient
- **Email templates** — optional integration with PhoenixKit Emails module (soft dependency via `Code.ensure_loaded?`)
- **Delivery tracking** — per-recipient status lifecycle: pending → sent → delivered → opened / bounced / failed
- **Unsubscribe flow** — signed Phoenix.Token links (7-day expiry) for single-list or all-lists unsubscribe
- **Admin UI** — 6 LiveViews: Broadcasts index/editor/details, Lists index/editor, ListMembers
- **Rate limiting** — configurable via `newsletters_rate_limit` setting (default 14/sec)

### Architecture

- Implements `PhoenixKit.Module` behaviour with auto-discovery via `@phoenix_kit_module true`
- UUIDv7 primary keys on all schemas (Broadcast, Delivery, List, ListMember)
- Admin routes auto-generated from `admin_tabs/0`; public routes via `route_module/0`
- Configurable endpoint for token signing/verification (`PhoenixKit.Config.get(:endpoint)`)
- LiveView best practices: all DB queries in `handle_params/3`, not `mount/3`

### Dependencies

- Requires `phoenix_kit ~> 1.7.73`
- Requires Oban `~> 2.20`, Phoenix LiveView `~> 1.1`, Earmark `~> 1.4`
