# AGENTS.md

Guidance for AI agents working on `phoenix_kit_newsletters`.

## Overview

A library (not a standalone Phoenix app) that plugs into a PhoenixKit host as
the "newsletters" module: admin LiveViews for composing, scheduling and
sending email broadcasts, Oban-based per-recipient delivery with rate
limiting, and public unsubscribe / subscription-preference pages that work
from a signed token with no login. It implements `PhoenixKit.Module` and
borrows the host's Repo, Mailer, Endpoint, Oban instance, Users and Settings.

It starts exactly one process of its own: `PhoenixKit.Newsletters.Application`
(the `:mod` in `mix.exs`) supervises `PhoenixKit.Newsletters.AttachmentCache`,
which exists only to own the attachment cache's ETS table (an ETS table dies
with its owner, and Oban job processes are too short-lived to own a cache
shared across jobs). Nothing else belongs in that supervision tree; background
work goes through Oban workers.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex); `phoenix_live_view ~> 1.1`,
  `oban ~> 2.20`, `mdex ~> 0.13`, `uuidv7 ~> 1.0`, `gettext ~> 1.0`. Optional
  at runtime, guarded with `Code.ensure_loaded?/1`: core's Emails module
  (`PhoenixKit.Modules.Emails.*`, wrapper templates) and `phoenix_kit_crm`
  (`PhoenixKitCRM.*`, contact-list audiences and the preference center).
  `phoenix_kit_crm ~> 0.6` is a `only: :test` dep so the CRM path is tested
  against real CRM schemas, not just the "CRM not installed" degrade path.
- **Consumed by:** nothing calls its API. Core's
  `PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker` looks the
  module up by key and calls `enabled?/0` + `process_scheduled_broadcasts/0`
  on its periodic tick; that is the host contract for scheduled sends.
- **Admin surface:** tab `:admin_newsletters` (`/admin/newsletters/broadcasts`,
  priority 520, group `:admin_modules`, permission `"newsletters"`) with
  subtabs Broadcasts (`/broadcasts`), New (`/broadcasts/new`, hidden), Edit
  (`/broadcasts/:id/edit`, hidden), Details (`/broadcasts/:id`, hidden). One
  user-dashboard tab `:dashboard_newsletters_preferences` (group `:account`,
  absolute path `/newsletters/preferences`, no `live_view`, visible only when
  CRM is installed).
- **Module key** `"newsletters"`; settings prefix `newsletters_`.

## What this module does NOT do

- Owns no tables and no migration chain; every table lives in core's chain.
- Has no mailing lists of its own. An audience is either a CRM contact list
  (`source_type "crm_list"`) or a set of core roles (`"user_group"`). The
  former `List`/`ListMember` schemas and the `"newsletters_list"` source type
  no longer exist; a stale token or row of that flavour must degrade, never
  crash (see the unsubscribe controller).
- Never hard-depends on CRM or Emails. Both are soft dependencies; every
  feature that needs them degrades to "unavailable" / no template.
- No cross-broadcast rate limiter. The throttle is scoped to one broadcast;
  two concurrent sends through one profile can exceed its caps together.
  Provider-side quotas are the backstop.
- No activity logging; nothing here writes to core's activity log.
- Does not dequeue anything on "Cancel broadcast". The cancel writes only the
  broadcast row; the queued jobs still run, and each one stops itself on the
  worker's broadcast-status guard (see Send pipeline step 5). Stopping is
  worker-side by design — it is the only point that closes the race against a
  job already executing.
- Does not process provider delivery/open/bounce events itself; it only
  exposes `find_delivery_by_message_id/1` and `update_delivery_status/3` for
  a caller that does.

## Commands

```bash
mix deps.get
createdb phoenix_kit_newsletters_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex and this module does not carry the
`pk_dep/3` helper. To run against a local core checkout, temporarily change the
dep to `{:phoenix_kit, path: "../phoenix_kit", override: true}` in `mix.exs`,
run `mix deps.get`, and revert **both** `mix.exs` and `mix.lock` before
committing (switching between path and Hex resolution rewrites the lock).

`mix precommit` also runs `deps.unlock --check-unused` and `mix hex.audit`.

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- Module key `"newsletters"` is the same string in `module_key/0`,
  `permission_metadata/0`, `enable_system/0`/`disable_system/0` and the
  `newsletters_enabled` setting. Tab ids are prefixed `admin_newsletters_`;
  tab paths and URL segments use hyphens, never underscores.
- Paths: `PhoenixKit.Newsletters.Paths` for this module's own admin and
  public URLs, `PhoenixKit.Utils.Routes.path/1` for cross-module links and
  any path built from a string; `Routes.url/1` for the absolute links that go
  into emails. Never a relative path, never a hardcoded host. (A few templates
  still pass literal `/admin/newsletters/...` strings to `pk_link`; route new
  code through `Paths`.)
- Routing: admin routes come only from `live_view:` on the tabs in
  `admin_tabs/0`; public routes come only from `route_module/0`
  (`PhoenixKit.Newsletters.Web.Routes.generate/1`). Never hand-register either
  in a host router; core's `guides/custom-admin-pages.md` is the reference.
  The preference center is a `live_session` inside `Web.Routes`, not a
  dashboard-tab route, because dashboard live_sessions require a login and
  this page must open from a signed token without one; its dashboard tab
  therefore carries an absolute `path` and no `live_view`.
- The one-click unsubscribe route (`GET`/`POST /newsletters/unsubscribe/one-click`)
  runs through its own `:phoenix_kit_newsletters_one_click` pipeline that only
  does `accepts ["html"]`. It must stay outside the host's `:browser`
  pipeline: a mail client's RFC 8058 POST carries no CSRF token or session.
- LiveViews `use Phoenix.LiveView` + `use Gettext, backend:
  PhoenixKit.Newsletters.Gettext` and import core components explicitly
  (`PhoenixKitWeb.Components.Core.{Icon, PkLink, EmptyState, TableDefault}`);
  they do not use `PhoenixKitWeb, :live_view`. The three admin templates wrap
  in `PhoenixKitWeb.Components.LayoutWrapper.app_layout`; the preference
  center wraps in `AuthPageWrapper.auth_page_wrapper`. The controller and its
  HTML module use `PhoenixKitWeb, :controller` / `:html`.
- Assigns available in admin LiveViews: `@phoenix_kit_current_scope`,
  `@phoenix_kit_current_user`, `@current_locale`, `@url_path`. Reference
  `@phoenix_kit_current_user` through `assign_new/3` so the template can use
  the tracked `@` form; the untracked `assigns[...]` form re-renders the media
  picker on every keystroke.
- Work that must run once per connection (token verification, timezone
  resolution, the account-path contact find-or-link write) goes in
  `handle_params/3`, not `mount/3`, which runs twice.
- Gettext: own backend `PhoenixKit.Newsletters.Gettext` with
  `priv/gettext/{en,et,ru}`; every `Tab.new!` passes `gettext_backend:`.
  Refresh with `mix gettext.extract --merge`. Bare `Tab.new!(label:)` literals
  are invisible to the extractor: hand-list each new tab label in the
  "Sidebar tab labels" block at the top of `priv/gettext/default.pot`, then
  merge. `I18nTest` fails when a tab label lacks a non-identity `ru`
  translation.
- JS hooks: none. If one is ever needed it ships via `js_sources/0` under a
  namespaced global, never from an inline `<script>` (morphdom does not
  execute inserted script tags, so an inline hook vanishes on LiveView
  navigation). `css_sources/0` returns `[:phoenix_kit_newsletters]`.
- `enabled?/0` reads `newsletters_enabled` and rescues any exception to
  `false` (it does not catch `:exit`). Every LiveView `mount/3` checks it and
  redirects with a flash when the module is disabled.
- Activity logging: none.
- Soft-delete sentinel: none. `delete_broadcast/1` only deletes `"draft"`
  broadcasts; anything else returns `{:error, :cannot_delete_non_draft}`.
- Soft dependencies: guard every reference to `PhoenixKit.Modules.Emails.*`
  or `PhoenixKitCRM.*` with `Code.ensure_loaded?/1` and call through
  `apply/3` (`soft_call/3`, credo-disabled on purpose). Ecto's `from`/`join`
  DSL introspects a literal schema module at compile time and a module
  attribute does not avoid that, so `CRMSource` builds CRM schema atoms with
  `Module.concat/1` inside functions. `required_modules/0` returns
  `["emails"]`; the module still works without Emails installed (template
  wrapping is skipped).
- UUIDv7 primary keys: `@primary_key {:uuid, UUIDv7, autogenerate: true}` on
  both schemas, `use PhoenixKit.SchemaPrefix` on both
  (`SchemaPrefixConformanceTest` enforces it). A core migration touching these
  tables uses `uuid_generate_v7()`, never `gen_random_uuid()`.
- Background work is Oban only (`DeliveryWorker`, queue `newsletters_delivery`,
  `max_attempts: 3`, unique on `delivery_uuid` while incomplete). Never spawn a
  bare `Task` for email work.
- Core pin: keep `{:phoenix_kit, "~> 2.0"}` two-segment.
  `CorePinConformanceTest` rejects a three-segment `~> 2.0.x` (it excludes
  every later core minor and breaks `mix deps.get` for hosts) and a committed
  `path:` dep. Raise the floor only when a new core migration is required.
- Timezones: storage is UTC. Display goes through
  `Web.Timezone.viewer_tz/1` (profile `user_timezone`, then the `time_zone`
  setting, then `"0"`) and core's per-instant helpers; labels come from
  `Settings.get_timezone_label/1`. Never keep a private copy of core's
  timezone list.
- Broadcast content: Markdown renders through `Content` with MDEx and is
  always run through `PhoenixKit.Utils.HtmlSanitizer` (it is mailed to
  strangers, not previewed by an admin). Variable substitution is one pass
  over `{{name}}`, `{{email}}`, `{{unsubscribe_url}}`, `{{preferences_url}}`;
  the wrapper template is applied first (`{{content}}`), variables second; an
  unknown tag stays literal, and an unresolved `preferences_url` is omitted
  from the map so the literal tag stays visible rather than becoming a link
  to `/`.

### Landmines

- Host Oban queue is `newsletters_delivery` (core's installer adds it). A
  host that configures `newsletters:` instead never runs a single delivery
  job — the jobs enqueue fine and nothing drains them. The README's Oban
  snippet names the right queue now; keep it that way.
- `DeliveryWorker.perform/1` sends only when the broadcast's status is
  `"sending"` (`@sendable_broadcast_statuses`, checked by
  `guard_broadcast_sendable/1` right after `get_broadcast/1`). It is an
  **allow-list on purpose**: `Broadcaster.do_send/1` flips to `"sending"`
  before it enqueues anything, so that is the only status a real job ever
  runs under, and a new status added later stalls a send rather than
  sending under it. For irreversible mass email that asymmetry decides the
  direction — a stalled send is recoverable and visible, mail already handed
  to a provider is neither. Never widen this to a deny-list.
- **The guard is checked twice.** `recheck_broadcast_sendable/1` runs again
  immediately before `send_email/7`, because recipient lookup, rendering and
  `resolve_attachments/1` (which downloads files) sit between the first check
  and the send and can take seconds. It costs one indexed read per delivery
  and narrows the cancel race to the provider call itself, which nothing in a
  database can retract. Cancellation therefore means "stops every delivery
  that has not already been handed to the provider", not "stops everything".
- Both guards return plain `:ok` (like the already-sent skip) so the job
  neither retries nor records a failure, and write **nothing** to the
  delivery row: `"pending"` is honest for a send that never happened, and any
  terminal status would clear the broadcast's last non-terminal delivery —
  the exact condition `maybe_finalize_broadcast/1` watches — while `"failed"`
  would also inflate `bounced_count` with an operator's own cancellation.
- `insert_all` bypasses `Delivery.changeset/2`. `Broadcaster.process_batch/5`
  re-checks "user_uuid or recipient_email present" by hand and relies on the
  DB CHECK plus the three partial unique indexes
  (`idx_newsletters_deliveries_uniq_broadcast_{user,contact,email}`) via
  `on_conflict: :nothing` with no `conflict_target`. Adding a new recipient
  source means adding its unique index in core first.
- The SMTP adapter returns a raw receipt string, not a map;
  `extract_message_id/1` must never raise. A raise after the provider
  accepted the message makes Oban resend the same email up to three times.
- A transient delivery failure must keep `status: "pending"` (the only
  non-terminal status). Writing `"failed"` early lets a broadcast finalize to
  `"sent"` while a retry is still queued.
- The unsubscribe token salts are load-bearing: `"unsubscribe"` for CRM
  claims `%{contact_uuid, crm_list_uuid}`, `"newsletters_user_optout"` for
  `%{user_uuid}` (tagged `{:role_optout, _}` by `verify_token/1`),
  `"newsletters_preferences"` for `%{contact_uuid}`. Do not merge them; a
  per-list link must never open the full preference page.
- Never mutate on `GET`. Link scanners fetch every URL in an email; only the
  `POST` handlers unsubscribe, and the `GET` one-click route redirects to the
  confirm page.
- `test_helper.exs` prints a "core V158 … not present" warning whenever the
  test DB is unreachable; it is the same condition as the `:integration`
  exclusion, not a second problem.

## Architecture

```
lib/phoenix_kit/newsletters/
├── newsletters.ex          # PhoenixKit.Module callbacks + broadcast/delivery context, scheduled processing
├── application.ex          # Supervises AttachmentCache only
├── attachment_cache.ex     # Public ETS cache of resolved Swoosh attachments, 2 min TTL, 1 min sweep
├── broadcast.ex            # Broadcast schema
├── delivery.ex             # Delivery schema + non_terminal_broadcast_uuids_query/0
├── broadcaster.ex          # send/1: validates source, renders, inserts deliveries in batches, enqueues jobs
├── content.ex              # Markdown -> sanitized HTML, HTML -> text
├── crm_source.ex           # Soft-dep bridge to PhoenixKitCRM lists/contacts
├── user_group_source.ex    # Role-based audience; opt-out via users.custom_fields["newsletters_opted_out_at"]
├── preference_token.ex     # Preference-center token (salt "newsletters_preferences")
├── paths.ex                # Admin + public path helpers
├── gettext.ex              # PhoenixKit.Newsletters.Gettext backend
├── web/
│   ├── routes.ex           # route_module/0: unsubscribe routes + preference-center live_session
│   ├── broadcasts.ex/.heex          # Admin list, status filter via push_patch
│   ├── broadcast_editor.ex/.heex    # Compose/edit, source picker, preflight, attachments, send/schedule
│   ├── broadcast_details.ex/.heex   # Stats, deliveries, cancel, retry
│   ├── preference_center_live.ex/.heex  # Public self-service subscriptions (token or login)
│   ├── unsubscribe_controller.ex    # GET confirm pages, POST unsubscribe, one-click endpoint
│   ├── unsubscribe_html.ex + unsubscribe_html/*.heex
│   ├── send_error.ex       # Broadcaster.send/1 reasons -> localized sentences (shared by editor + details)
│   └── timezone.ex         # viewer_tz/1, tz_label/1, format_datetime/2
└── workers/
    └── delivery_worker.ex  # One email per job: render, attach, send via profile or legacy mailer, record result
```

### Data model

| Schema | Table | Notes |
|---|---|---|
| `Broadcast` | `phoenix_kit_newsletters_broadcasts` | statuses `draft → scheduled → sending → sent`, plus `cancelled`, `failed`; `source_type` `"crm_list"` (needs `crm_list_uuid`) or `"user_group"` (needs `source_params["role_uuids"]`, with `role_names_snapshot` display-only); `attachments` = up to 10 distinct Storage file uuids in send order; `template_uuid`, `send_profile_uuid`, `crm_list_uuid` are bare soft references, no FK |
| `Delivery` | `phoenix_kit_newsletters_deliveries` | statuses `pending` (only non-terminal), `sent`, `delivered`, `opened`, `bounced`, `failed`, `blocked`; exactly one owner: `user_uuid` (role recipient) or `crm_contact_uuid` + `recipient_email` (CRM recipient); `message_id` unique |

Roles are resolved by uuid, never by name: a role's name is mutable, so a
broadcast that stored names would silently re-target on rename.

### Send pipeline

1. `Broadcaster.send/1` accepts `draft`, `scheduled` or `failed`; refuses a
   `crm_list` broadcast whose list is not `active`
   (`{:crm_list_not_active, status}`) before touching status.
2. Renders Markdown, flips to `sending`, resolves recipients once
   (`CRMSource.sendable_recipients/1`: subscribed, not opted out, has email,
   deduplicated by downcased email; `UserGroupSource.sendable_recipients/1`:
   active, not opted out, deduplicated by user).
3. Inserts deliveries in batches of 500 inside one transaction and enqueues one
   `DeliveryWorker` job per inserted row. `total_recipients` is corrected to
   the real row count afterwards so a resend never zeroes it.
4. Throttle: `send_interval_seconds/1` takes the tightest of the send
   profile's `rate_per_hour`, `rate_per_day`, `pause_seconds`; job N is
   scheduled `N × interval` seconds out, continuous across batches. `0` means
   enqueue everything at once.
5. `DeliveryWorker.perform/1`: skips a delivery already `sent`; re-reads the
   broadcast and skips it entirely when its status is `cancelled` or `failed`
   (this is what makes "Cancel broadcast" stop a send in flight — the button
   itself only writes the broadcast row, and the throttle means most jobs are
   still queued minutes or hours out when it is pressed); resolves the
   send profile (broadcast's own if enabled, else the default, else the legacy
   `PhoenixKit.Mailer.deliver_email/1` path with `from_email`/`from_name`
   settings); adds `List-Unsubscribe` + `List-Unsubscribe-Post` headers when a
   one-click URL resolved; resolves attachments last and drops an unreadable
   one with a warning rather than failing the send.
6. Result handling runs in one transaction (`update_delivery_result/5`):
   status write, counter bump, and the finalize check that flips the
   broadcast to `sent` once no delivery is `pending`. Permanent failures
   (`{:blocked, _}`, `:deleted`, `:not_configured`, `:unsupported_provider`,
   `{:invalid_smtp_port, _}`) cancel the job and touch no counter, so a
   blocklisted address never inflates `bounced_count`; a terminal transient
   failure counts as a bounce.
7. `process_scheduled_broadcasts/0` first runs
   `repair_stuck_sending_broadcasts/0` (one batch UPDATE), then sends every
   `scheduled` broadcast whose time has passed; a `{:crm_list_not_active, _}`
   error marks the broadcast `failed` (terminal, retryable from the details
   page) instead of re-failing every tick.

### Public flows

| Route | Behaviour |
|---|---|
| `GET /newsletters/unsubscribe?token=` | Confirm page only; renders `:confirm`, `:already_unsubscribed` or `:invalid` |
| `POST /newsletters/unsubscribe` `scope=list` | Removes the contact from that CRM list (idempotent) |
| `POST /newsletters/unsubscribe` `scope=all` | Contact-level opt-out across every list |
| `POST /newsletters/unsubscribe` `scope=role_optout` | `UserGroupSource.record_opt_out/1`: writes `custom_fields["newsletters_opted_out_at"]` and, when a CRM contact is linked, its `opted_out_at` too |
| `GET /newsletters/unsubscribe/one-click` | Redirects to the confirm page, never mutates |
| `POST /newsletters/unsubscribe/one-click` | RFC 8058: unsubscribes and always answers 200 |
| `GET /newsletters/preferences[?token=]` | Preference center: token grants access to that contact; without a token an authenticated user's contact is found or lazily created and linked (never via `Contacts.connect_user/2`; an email held by several unlinked contacts counts as no match) |

Tokens are `Phoenix.Token`, endpoint from `PhoenixKit.Config.get(:endpoint,
PhoenixKitWeb.Endpoint)`, `max_age` 7 days, salts as listed under Landmines.

### Settings keys

| Key | Read by | Default |
|---|---|---|
| `newsletters_enabled` | `enabled?/0` | `false` |
| `newsletters_default_template` | editor, when Emails is installed | none |
| `from_email`, `from_name` | worker, when the profile or legacy path has no sender | `noreply@example.com` / `Newsletter` |
| `time_zone` | `Web.Timezone` fallback | `"0"` |

There is no `newsletters_rate_limit` setting. It was documented in the README
and the worker's `@moduledoc` but read by nothing, and both mentions are gone;
do not re-add it. Rate control is queue concurrency
(`newsletters_delivery`) plus the send profile's own
`rate_per_hour`/`rate_per_day`/`pause_seconds`, which
`Broadcaster.send_interval_seconds/1` turns into per-job scheduling.

Permission: single key `"newsletters"` on every admin tab; no sub-permissions.
PubSub: none.

## Database & migrations

None. Tables `phoenix_kit_newsletters_broadcasts` and
`phoenix_kit_newsletters_deliveries` ship in core's chain (V135 baseline, later
core migrations add `source_type`/`crm_list_uuid`/`source_params`,
`send_profile_uuid`, `attachments`, the delivery owner CHECK and the partial
unique indexes); `migration_module/0` is unset. A schema change is a core
migration first, then schema edits here. `mix phoenix_kit.update` in the host
applies it. Always UUIDv7 PKs and `use PhoenixKit.SchemaPrefix` on
table-backed schemas.

The broadcasts table's DB column default for `source_type` is still the
retired `'newsletters_list'`; the Ecto default `"crm_list"` is what every
insert through the changeset uses.

## Testing

- Test DB `phoenix_kit_newsletters_test` (`MIX_TEST_PARTITION` suffix
  honoured); `PGUSER`, `PGPASSWORD`, `PGHOST` are read with `postgres` /
  `postgres` / `localhost` defaults.
- `test_helper.exs` starts `PhoenixKitNewsletters.Test.Repo`, brings it to
  the current core schema with `PhoenixKit.Migration.ensure_current/2`, sets
  sandbox `:manual`, and starts `PhoenixKit.PubSub.Manager` (role fixtures
  broadcast through it). No reachable DB excludes `:integration`; it also
  probes the `attachments` column with a real query and excludes
  `:requires_v158` when absent (every core ≥ 2.0 has it, so in practice both
  tags skip together).
- `PhoenixKitNewsletters.DataCase` tags `:integration`, checks out the
  sandbox, and provides `errors_on/1`. Support modules: `DataCase`,
  `Test.Repo`. There is no test Endpoint, Router or Layouts, so LiveView
  tests call `mount/3`, `handle_params/3` and `handle_event/3` directly on a
  hand-built `%Phoenix.LiveView.Socket{}`; controller tests build a
  `Plug.Test` conn with a cookie session and `fetch_flash`.
- `config/test.exs` wires `config :phoenix_kit, repo:`, a `secret_key_base`
  (so integration credentials round-trip encrypted), `PhoenixKit.Mailer` to
  `Swoosh.Adapters.Test`, and `:endpoint` to a raw secret string so
  `Phoenix.Token` signs without a running Endpoint.
- Runs without Postgres: behaviour compliance, `CorePinConformanceTest`,
  `SchemaPrefixConformanceTest`, `I18nTest`, content, preference token,
  attachment cache, send-error, provider-options, controller and broadcaster
  unit tests.
- Worker seams exposed as public `@doc false` functions for direct unit
  tests: `resolve_send_profile/1`, `build_profile_email/5`,
  `extract_message_id/1`, `compose_html/3`, `handle_failure/4`,
  `update_delivery_result/5`, `resolve_attachments/2`, `build_attachment/2`,
  `maybe_put_list_unsubscribe_headers/3`, `permanent_failure?/1`,
  `Broadcaster.valid_recipient?/1`.

## Feature notes

None. Feature behaviour is documented in `@moduledoc`s; the invariants are
listed under Conventions, Landmines and Architecture above.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

`mix docs` uses `source_ref: @version`, so the tag form and the version
string must agree or every HexDocs source link 404s.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **A terminal delivery status for suppressed sends.** Deliveries under a
  cancelled broadcast stay `"pending"` forever. That is safe (finalization
  and the repair sweep both match `status == "sending"` only, so nothing
  sweeps them) and honest, but it means a delivery row and its Oban job
  disagree — the job completed, the delivery reads non-terminal — so any
  future report counting pending deliveries, or a resume/retry-pending
  feature, must join against the broadcast's status or it will mis-read
  them. The clean model is a terminal `"cancelled"` status excluded from
  `bounced_count` and from `non_terminal_broadcast_uuids_query/0`.
  **Trigger:** the first reporting or resume feature that reads delivery
  status without the broadcast join. Needs a `@valid_statuses` change and a
  decision on backfilling existing rows; do NOT reuse `"failed"`.
- **Bulk-cancel the queued Oban jobs on cancel.** Cancelling a
  50k-recipient broadcast currently wakes all 50k jobs, each doing two
  reads and an info log, just to skip. `Oban.cancel_all_jobs/1` over the
  broadcast's jobs would drop that to one statement. The worker guards stay
  either way — they are what closes the race — so this is a cost fix, not a
  correctness one. **Trigger:** a real send large enough for the wake-up
  cost to show.

- `README.md` still describes the retired `List`/`ListMember` model and the
  old unsubscribe token payload (`%{user_uuid, list_uuid}`, a
  `/unsubscribe/:token` path, `list_uuid: :all`) — none of which exist any
  more; its "Modules" table still lists `Web.Lists` / `Web.ListEditor` /
  `Web.ListMembers`. Rewrite it from this file when the README is next
  touched. The Oban queue name and the settings table are current.
