# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Newsletters — an Elixir module for email broadcasts and subscription management, built as a pluggable module for the PhoenixKit framework. Provides admin LiveViews for managing lists/broadcasts, Oban-based background delivery, and public unsubscribe flows.

## Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests
mix test test/file_test.exs # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix docs                    # Generate documentation
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Architecture

This is a **library** (not a standalone Phoenix app) that provides newsletters as a PhoenixKit plugin module. It implements the `PhoenixKit.Module` behaviour and depends on the host PhoenixKit app for Repo, Mailer, Endpoint, Users, and Settings.

### Core Schemas (all use UUIDv7 primary keys)

- **List** — newsletter mailing list with name, slug, status
- **Broadcast** — email content (Markdown -> HTML), status lifecycle: draft -> scheduled -> sending -> sent
- **ListMember** — subscription join table (user <-> list), unique constraint on [user_uuid, list_uuid]
- **Delivery** — per-recipient tracking record, status: pending -> sent -> delivered -> opened / bounced / failed

### Broadcast Sending Pipeline

`Broadcaster` orchestrates sending: renders Markdown, streams list members in batches of 500, creates Delivery records via `insert_all`, enqueues `DeliveryWorker` Oban jobs. The worker sends individual emails with variable substitution (`{{name}}`, `{{email}}`, `{{unsubscribe_url}}`), optionally wraps in an email template (soft dependency on Emails module), and tracks delivery status.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `route_module/0` provides additional public routes (unsubscribe) via `Web.Routes`
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Web Layer

- **Admin** (6 LiveViews): Broadcasts index/editor/details, Lists index/editor, ListMembers — all use `Phoenix.LiveView` directly (not `PhoenixKitWeb` macros)
- **Public** (1 Controller): `UnsubscribeController` handles token-verified unsubscribe (single list or all lists)
- **Routes**: `route_module/0` provides public routes; admin routes auto-generated from `admin_tabs/0`. Never hand-register these routes in the parent app's `router.ex`; see `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Soft Dependencies

Uses `Code.ensure_loaded?` guards for optional integration with `PhoenixKit.Modules.Emails` (templates). The module declares `required_modules: ["emails"]` but degrades gracefully without it.

### Settings Keys

`newsletters_enabled`, `newsletters_default_template`, `newsletters_rate_limit` (default 14/sec), `from_email`, `from_name`

### Unsubscribe Tokens

Signed with `Phoenix.Token` using `"unsubscribe"` salt, max age 7 days, payload: `{user_uuid, list_uuid}`.

### File Layout

```
lib/phoenix_kit/newsletters/
├── newsletters.ex                     # Main module (PhoenixKit.Module behaviour + context)
├── broadcast.ex                       # Broadcast Ecto schema
├── broadcaster.ex                     # Broadcast sending orchestrator
├── content.ex                         # Content rendering (Markdown -> HTML)
├── delivery.ex                        # Delivery Ecto schema
├── list.ex                            # List Ecto schema
├── list_member.ex                     # ListMember Ecto schema
├── paths.ex                           # Centralized URL path helpers
├── web/
│   ├── routes.ex                      # Public route generation
│   ├── unsubscribe_controller.ex      # Public unsubscribe handler
│   ├── unsubscribe_html.ex            # Unsubscribe view module
│   ├── unsubscribe_html/
│   │   └── unsubscribe.html.heex      # Unsubscribe template
│   ├── broadcasts.ex                  # Broadcasts list LiveView
│   ├── broadcasts.html.heex
│   ├── broadcast_editor.ex            # Broadcast create/edit LiveView
│   ├── broadcast_editor.html.heex
│   ├── broadcast_details.ex           # Broadcast details LiveView
│   ├── broadcast_details.html.heex
│   ├── lists.ex                       # Lists index LiveView
│   ├── lists.html.heex
│   ├── list_editor.ex                 # List create/edit LiveView
│   ├── list_editor.html.heex
│   ├── list_members.ex                # List members LiveView
│   └── list_members.html.heex
└── workers/
    └── delivery_worker.ex             # Oban worker for individual email delivery
```

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"newsletters"`
- **UUIDv7 primary keys** — all schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}` and `uuid_generate_v7()` in migrations (never `gen_random_uuid()`)
- **Oban workers** — all background tasks (delivery, scheduled broadcasts) use Oban workers; never spawn bare Tasks for async email work
- **Soft dependency on Emails module** — always guard with `Code.ensure_loaded?(PhoenixKit.Modules.Emails.Template)` before referencing Emails schemas or functions; the module must work without Emails installed
- **Centralized paths via `Paths` module** — never hardcode URLs or route paths in LiveViews or controllers; use `Paths` helpers or `PhoenixKit.Utils.Routes.path/1` for cross-module links
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs returned by `admin_tabs/0`; do not manually add admin routes elsewhere
- **Public routes from `route_module/0`** — the single public entry point is `Web.Routes`; `route_module/0` returns this module so PhoenixKit registers public routes automatically
- **LiveViews use `Phoenix.LiveView` directly** — do not use `PhoenixKitWeb` macros (`use PhoenixKitWeb, :live_view`) in this standalone package; import helpers explicitly
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`

## Database & Migrations

This repo contains **no database migrations**. All database tables and migrations live in the parent [phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) project. This module only defines Ecto schemas that map to tables created by PhoenixKit core.

## Testing

### Structure

```
test/
├── test_helper.exs                                    # ExUnit setup
├── phoenix_kit_newsletters_test.exs                   # Unit tests (behaviour compliance)
└── phoenix_kit/newsletters/
    ├── broadcaster_test.exs                           # Broadcaster unit tests
    ├── content_test.exs                               # Content rendering tests
    └── web/
        └── unsubscribe_controller_test.exs            # Unsubscribe controller tests
```

### Running tests

```bash
mix test                                                # All tests
mix test test/phoenix_kit_newsletters_test.exs          # Behaviour compliance tests
mix test test/phoenix_kit/newsletters/content_test.exs  # Content tests only
```

## Versioning & Releases

### Version locations

The version is defined in `mix.exs` (`@version` attribute) and derived at compile time in `lib/phoenix_kit/newsletters/newsletters.ex` via `unquote(Mix.Project.config()[:version])`.

### Changelog

Update `CHANGELOG.md` before releasing. Each version gets a section:

```markdown
## x.y.z - YYYY-MM-DD

### Added / Changed / Fixed / Removed
- Description of change
```

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-28" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`).

### Review file format

```markdown
# Code Review: PR #<number> — <title>

**Reviewed:** <date>
**Reviewer:** Claude (claude-opus-4-6)
**PR:** <GitHub URL>
**Author:** <name> (<GitHub login>)
**Head SHA:** <commit SHA>
**Status:** <Merged | Open>

## Summary
<What the PR does>

## Issues Found
### 1. [<SEVERITY>] <title> — <FIXED if resolved>
**File:** <path> lines <range>
**Confidence:** <score>/100

## What Was Done Well
<Positive observations>

## Verdict
<Approved | Approved with fixes | Needs Work> — <reasoning>
```

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `NITPICK`, `OBSERVATION`

When issues are fixed in follow-up commits, append `— FIXED` to the issue title and update the Verdict section.

Additional files per PR directory:
- `README.md` — PR summary (what, why, files changed)
- `FOLLOW_UP.md` — post-merge issues, discovered bugs
- `CONTEXT.md` — alternatives considered, trade-offs

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper, Utils (Date, UUID, Routes), Users.Auth.User, Users.Roles
- **Phoenix LiveView** (`~> 1.1`) — Admin LiveViews
- **Oban** (`~> 2.20`) — Background job processing (email delivery)
- **Earmark** (`~> 1.4`) — Markdown to HTML rendering for broadcast content
- **UUIDv7** (`~> 1.0`) — UUIDv7 primary key generation
- **ex_doc** (`~> 0.39`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis / code quality
- **dialyxir** (`~> 1.4`, dev/test) — Static type checking
