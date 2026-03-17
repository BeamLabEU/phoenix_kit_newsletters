# phoenix_kit_newsletters

Newsletters module for PhoenixKit — email broadcasts and subscription management.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_newsletters, "~> 0.1"}
    # During development (before Hex publish):
    # {:phoenix_kit_newsletters, github: "BeamLabEU/phoenix_kit_newsletters"}
  ]
end
```

## Oban Setup

PhoenixKit Newsletters uses Oban for background email delivery. Add the newsletters queue to your Oban configuration:

```elixir
# In config/config.exs:
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [newsletters: 10]
```

See the [Oban documentation](https://hexdocs.pm/oban) for full configuration options.

## How It Works

PhoenixKit Newsletters auto-registers with PhoenixKit on startup — no additional configuration needed.

1. Run `mix deps.get`
2. Recompile PhoenixKit routes: `mix deps.compile phoenix_kit --force`
3. Restart your server
4. Enable the module in **Admin > Modules > Newsletters**

Migrations are managed by PhoenixKit core and applied automatically via `mix phoenix_kit.update`.

## Requirements

| Dependency | Version |
|---|---|
| Elixir | `~> 1.18` |
| PhoenixKit | `>= 1.7.73` |
| Phoenix LiveView | `~> 1.1` |
| Oban | `~> 2.20` |
| Earmark | `~> 1.4` |

## Architecture

PhoenixKit Newsletters implements the `PhoenixKit.Module` behaviour and plugs into the host PhoenixKit app. It depends on the host for Repo, Mailer, Endpoint, Users, and Settings.

### Core Schemas

All schemas use UUIDv7 primary keys.

| Schema | Description |
|---|---|
| `List` | Newsletter mailing list with name, slug, status |
| `Broadcast` | Email content (Markdown → HTML); status lifecycle: `draft → scheduled → sending → sent` |
| `ListMember` | Subscription join table (user ↔ list); unique constraint on `[user_uuid, list_uuid]` |
| `Delivery` | Per-recipient tracking record; status: `pending → sent → delivered → opened / bounced / failed` |

### Broadcast Sending Pipeline

`Broadcaster` orchestrates sending:

1. Renders Markdown to HTML via Earmark
2. Streams list members in batches of 500
3. Creates `Delivery` records via `insert_all`
4. Enqueues `DeliveryWorker` Oban jobs per recipient

`DeliveryWorker` sends individual emails with variable substitution (`{{name}}`, `{{email}}`, `{{unsubscribe_url}}`), optionally wraps in an email template (soft dependency on Emails module), and tracks delivery status.

## Modules

| Module | Role |
|---|---|
| `Newsletters` | Main context — CRUD for lists, members, broadcasts, deliveries |
| `Broadcaster` | Orchestrates batch sending and Oban job enqueuing |
| `DeliveryWorker` | Oban worker — sends individual emails, tracks delivery status |
| `Paths` | Centralized path helpers — always use instead of hardcoding URLs |
| `Web.Broadcasts` | Admin LiveView — broadcasts index |
| `Web.BroadcastEditor` | Admin LiveView — create/edit broadcast with Markdown editor |
| `Web.BroadcastDetails` | Admin LiveView — delivery stats and recipient list |
| `Web.Lists` | Admin LiveView — mailing lists index |
| `Web.ListEditor` | Admin LiveView — create/edit list |
| `Web.ListMembers` | Admin LiveView — list subscriber management |
| `Web.UnsubscribeController` | Public controller — token-verified unsubscribe flow |
| `Web.Routes` | Public route definitions via `route_module/0` |

## Settings

| Key | Default | Description |
|---|---|---|
| `newsletters_enabled` | `false` | Enables/disables the module |
| `newsletters_default_template` | — | Default email template UUID |
| `newsletters_rate_limit` | `14/sec` | Delivery rate limiting |
| `from_email` | — | Sender email address (shared with Emails module) |
| `from_name` | — | Sender display name (shared with Emails module) |

## Unsubscribe Flow

Unsubscribe tokens are signed with `Phoenix.Token` using the `"unsubscribe"` salt.

- **Max age**: 7 days
- **Payload**: `{user_uuid, list_uuid}`
- **Single list**: `GET /newsletters/unsubscribe/:token` — unsubscribes from one list
- **All lists**: token with `list_uuid: :all` — calls `unsubscribe_from_all/1`

The `UnsubscribeController` verifies the token, performs the unsubscribe, and renders a confirmation page.

## Development

```bash
mix deps.get        # Install dependencies
mix test            # Run all tests
mix format          # Format code
mix credo           # Lint / code quality
mix dialyzer        # Static type checking
```
