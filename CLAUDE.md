# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PhoenixKit Newsletters — an Elixir module for email broadcasts and subscription management, built as a pluggable module for the PhoenixKit framework. Provides admin LiveViews for managing lists/broadcasts, Oban-based background delivery, and public unsubscribe flows.

## Commands

```bash
mix test                    # Run all tests
mix test test/phoenix_kit_newsletters_test.exs   # Run single test file
mix test test/phoenix_kit_newsletters_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo                   # Lint / code quality
mix dialyzer                # Static type checking
mix deps.get                # Install dependencies
```

## Architecture

This is a **PhoenixKit module** that implements the `PhoenixKit.Module` behaviour. It depends on the host PhoenixKit app for Repo, Mailer, Endpoint, Users, and Settings.

### Core Schemas (all use UUIDv7 primary keys)

- **List** — newsletter mailing list with name, slug, status
- **Broadcast** — email content (Markdown → HTML), status lifecycle: draft → scheduled → sending → sent
- **ListMember** — subscription join table (user ↔ list), unique constraint on [user_uuid, list_uuid]
- **Delivery** — per-recipient tracking record, status: pending → sent → delivered → opened / bounced / failed

### Broadcast Sending Pipeline

`Broadcaster` orchestrates sending: renders Markdown, streams list members in batches of 500, creates Delivery records via `insert_all`, enqueues `DeliveryWorker` Oban jobs. The worker sends individual emails with variable substitution (`{{name}}`, `{{email}}`, `{{unsubscribe_url}}`), optionally wraps in an email template (soft dependency on Emails module), and tracks delivery status.

### Web Layer

- **Admin** (6 LiveViews): Broadcasts index/editor/details, Lists index/editor, ListMembers — all use `Phoenix.LiveView` directly (not `PhoenixKitWeb` macros)
- **Public** (1 Controller): `UnsubscribeController` handles token-verified unsubscribe (single list or all lists)
- **Routes**: `route_module/0` provides public routes; admin routes auto-generated from `admin_tabs/0`
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Soft Dependencies

Uses `Code.ensure_loaded?` guards for optional integration with `PhoenixKit.Modules.Emails` (templates). The module declares `required_modules: ["emails"]` but degrades gracefully without it.

### Settings Keys

`newsletters_enabled`, `newsletters_default_template`, `newsletters_rate_limit` (default 14/sec), `from_email`, `from_name`

### Unsubscribe Tokens

Signed with `Phoenix.Token` using `"unsubscribe"` salt, max age 7 days, payload: `{user_uuid, list_uuid}`.
