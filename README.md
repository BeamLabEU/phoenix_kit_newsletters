# phoenix_kit_newsletters

Newsletters module for PhoenixKit — email broadcasts and subscription management.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_newsletters, "~> 0.2"}
    # During development (before Hex publish):
    # {:phoenix_kit_newsletters, github: "BeamLabEU/phoenix_kit_newsletters"}
  ]
end
```

## Oban Setup

PhoenixKit Newsletters uses Oban for background email delivery. Add the
`newsletters_delivery` queue to your Oban configuration:

```elixir
# In config/config.exs:
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [newsletters_delivery: 10]
```

The queue name must be exactly `newsletters_delivery` — that is the queue
`PhoenixKit.Newsletters.Workers.DeliveryWorker` enqueues into. A host that
names it anything else enqueues jobs nothing drains and never sends a single
email. `mix phoenix_kit.install` adds this queue for you.

Queue concurrency is the delivery-rate ceiling. Per-broadcast pacing is
configured separately, on the send profile (`rate_per_hour`, `rate_per_day`,
`pause_seconds`), and applies to one broadcast at a time.

See the [Oban documentation](https://oban.hexdocs.pm) for full configuration options.

## How It Works

PhoenixKit Newsletters auto-registers with PhoenixKit on startup — no additional configuration needed.

1. Run `mix deps.get`
2. Recompile PhoenixKit routes: `mix deps.compile phoenix_kit --force`
3. Restart your server
4. Enable the module in **Admin > Modules > Newsletters**

This module owns and versions the future shape of its 2 tables
(`phoenix_kit_newsletters_broadcasts`, `phoenix_kit_newsletters_deliveries`)
through its own migration chain, `PhoenixKitNewsletters.Migrations`. Core's
`V135` baseline still CREATEs both tables on every install — this chain's
`V1` adopts that current shape (verbatim, including the five later core
migrations that layered send profiles, CRM-sourced recipients and
`attachments` on top) and stamps a version marker; it changes nothing else.
`mix phoenix_kit.update` in the host discovers and drives this chain the
same way it drives core's own.

## Requirements

| Dependency | Version |
|---|---|
| Elixir | `~> 1.18` |
| PhoenixKit | `~> 2.0` |
| Phoenix LiveView | `~> 1.1` |
| Oban | `~> 2.20` |
| MDEx | `~> 0.13` |

## Architecture

PhoenixKit Newsletters implements the `PhoenixKit.Module` behaviour and plugs into the host PhoenixKit app. It depends on the host for Repo, Mailer, Endpoint, Users, and Settings.

### Core Schemas

All schemas use UUIDv7 primary keys.

| Schema | Description |
|---|---|
| `Broadcast` | Email content (Markdown → HTML); status lifecycle: `draft → scheduled → sending → sent`, plus `cancelled`/`failed`. Audience is either a CRM contact list (`source_type "crm_list"`, `crm_list_uuid`) or a set of core roles (`source_type "user_group"`, `source_params["role_uuids"]`). Up to 10 Storage file attachments. |
| `Delivery` | Per-recipient tracking record; status: `pending → sent → delivered / opened / bounced / failed / blocked`. Exactly one owner: `user_uuid` (role recipient) or `crm_contact_uuid` + `recipient_email` (CRM recipient) — enforced by a DB CHECK constraint. |

There is no `List`/`ListMember` model any more — the old newsletters-owned
mailing lists were replaced by CRM contact lists / core roles and dropped
from the schema by core's `V156`.

### Broadcast Sending Pipeline

`Broadcaster` orchestrates sending:

1. Validates the source (a `crm_list` broadcast's list must be `active`), renders Markdown to HTML, flips the broadcast to `sending`
2. Resolves recipients once (deduplicated, opted-out/inactive excluded)
3. Inserts `Delivery` records in batches of 500 via `insert_all`, inside one transaction
4. Enqueues one `DeliveryWorker` Oban job per delivery, paced by the send profile's rate limits

`DeliveryWorker` sends individual emails with variable substitution (`{{name}}`, `{{email}}`, `{{unsubscribe_url}}`, `{{preferences_url}}`), optionally wraps in an email template (soft dependency on the Emails module), and tracks delivery status.

## Modules

| Module | Role |
|---|---|
| `Newsletters` | Main context — CRUD for broadcasts, deliveries, scheduled processing |
| `Migrations` | This module's own versioned migration chain (`migration_module/0`) |
| `Broadcaster` | Validates, renders and sends a broadcast; enqueues Oban jobs |
| `DeliveryWorker` | Oban worker — sends individual emails, tracks delivery status |
| `CRMSource` | Soft-dependency bridge to `phoenix_kit_crm` contact lists |
| `UserGroupSource` | Role-based audience resolution and opt-out |
| `Paths` | Centralized path helpers — always use instead of hardcoding URLs |
| `Web.Broadcasts` | Admin LiveView — broadcasts index |
| `Web.BroadcastEditor` | Admin LiveView — create/edit broadcast with Markdown editor |
| `Web.BroadcastDetails` | Admin LiveView — delivery stats and recipient list |
| `Web.PreferenceCenterLive` | Public LiveView — self-service subscription preferences (token or login) |
| `Web.UnsubscribeController` | Public controller — confirm/unsubscribe/one-click flow |
| `Web.Routes` | Public route definitions via `route_module/0` |

## Settings

| Key | Default | Description |
|---|---|---|
| `newsletters_enabled` | `false` | Enables/disables the module |
| `newsletters_default_template` | — | Default email template UUID (when Emails is installed) |
| `from_email` | `noreply@example.com` | Sender email address (shared with core, used by the legacy send path) |
| `from_name` | `Newsletter` | Sender display name (shared with core, used by the legacy send path) |

## Unsubscribe Flow

Tokens are `Phoenix.Token`, `max_age` 7 days, with three distinct salts —
never merge them, a per-list link must never open the full preference page:

| Salt | Payload | Used by |
|---|---|---|
| `"unsubscribe"` | `%{contact_uuid, crm_list_uuid}` | Per-list CRM unsubscribe link |
| `"newsletters_user_optout"` | `%{user_uuid}` | Role-recipient ("user_group") opt-out link |
| `"newsletters_preferences"` | `%{contact_uuid}` | Preference-center link |

| Route | Behaviour |
|---|---|
| `GET /newsletters/unsubscribe?token=` | Confirm page only; never mutates |
| `POST /newsletters/unsubscribe` (`scope=list`) | Removes the contact from that CRM list |
| `POST /newsletters/unsubscribe` (`scope=all`) | Contact-level opt-out across every list |
| `POST /newsletters/unsubscribe` (`scope=role_optout`) | Records the role recipient's opt-out |
| `GET /newsletters/unsubscribe/one-click` | Redirects to the confirm page, never mutates |
| `POST /newsletters/unsubscribe/one-click` | RFC 8058 one-click unsubscribe, always answers 200 |
| `GET /newsletters/preferences[?token=]` | Preference center (token, or an authenticated user's linked contact) |

The `UnsubscribeController` verifies the token and performs the requested
action; only `POST` handlers ever mutate state — a mail client's automatic
link-scanning `GET` never unsubscribes anyone.

## Removing this module

There is deliberately **no automated uninstall**.
`PhoenixKitNewsletters.Migrations.down/1` never drops either table or a row
in them, for any target version — a host that merely removes this
dependency from `mix.exs` has not consented to deleting every broadcast's
history and per-recipient delivery/bounce tracking, and a migration whose
result depended on which packages happen to be compiled in would be
nondeterministic. Removing the data is therefore a deliberate, manual
operator step, in FK-safe order (children before parents):

```sql
-- Only after removing :phoenix_kit_newsletters from mix.exs, and only if
-- you actually want every broadcast and its delivery history gone for
-- good. Does NOT touch phoenix_kit_email_send_profiles — that table
-- belongs to core, not this module.
DROP TABLE phoenix_kit_newsletters_deliveries;
DROP TABLE phoenix_kit_newsletters_broadcasts;
```

Dropping `phoenix_kit_newsletters_broadcasts` last also removes the
`pknl_schema:<N>` version marker, which is a `COMMENT` on that table — no
separate step is needed.

If you want to keep the tables (e.g. you plan to reinstall the module
later) but stop this chain from tracking them, clear the version marker
instead:

```sql
COMMENT ON TABLE phoenix_kit_newsletters_broadcasts IS NULL;
```

## Development

```bash
mix deps.get        # Install dependencies
mix test            # Run all tests
mix format          # Format code
mix credo           # Lint / code quality
mix dialyzer        # Static type checking
```
