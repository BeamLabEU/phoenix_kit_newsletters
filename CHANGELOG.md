# Changelog

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
