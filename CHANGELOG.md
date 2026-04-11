# Changelog

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
