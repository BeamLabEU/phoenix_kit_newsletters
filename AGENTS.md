# AGENTS.md

Guidance for AI agents working on `phoenix_kit_newsletters`. Keep this file
below 32 KiB and focused on working rules and invariants; use module docs for
implementation history and detailed API descriptions. Avoid repeating rules.

## Project & navigation

This is a library implementing `PhoenixKit.Module`, not a standalone Phoenix
app. It borrows the host's Repo, Mailer, Endpoint, Oban, Users and Settings.
Module key and permission base: `"newsletters"`; settings prefix: `newsletters_`.
Core's scheduled-jobs worker calls `enabled?/0` and
`process_scheduled_broadcasts/0` on its periodic tick.

`PhoenixKit.Newsletters.Application` supervises **only** `AttachmentCache`,
the ETS table owner (2 min TTL, 1 min sweep). Keep other processes out of this
supervision tree; background email work goes through Oban, never bare `Task`s.

Most source lives under `lib/phoenix_kit/newsletters/`:

- `newsletters.ex`: module callbacks, broadcast/delivery context, scheduling.
- `broadcaster.ex`, `workers/delivery_worker.ex`: batch enqueueing and delivery.
- `broadcast.ex`, `delivery.ex`, `layout.ex`, `layouts.ex`: schemas and layouts.
- `content.ex`, `render.ex`, `recipient_language.ex`: rendering and language.
- `crm_source.ex`, `user_group_source.ex`: audience bridges.
- `email_verification.ex`, `verification_engine.ex`, `verification_rows.ex`:
  host-engine bridge, compatibility contract, table data.
- `web/`: admin LiveViews/templates, public preferences/unsubscribe, routes,
  shared `SendError`, `LanguageOptions`, `Timezone`; `paths.ex`: URL helpers.
- `migrations.ex`: `PhoenixKitNewsletters.Migrations` versioned chain;
  `expected_schema.ex`: generated manifest exposed through `expected_schema/0`.

Dependency versions live in `mix.exs`. Keep core's published range
`>= 2.65.0 and < 4.0.0`: 2.65 supplies the module callbacks; the range admits
later 2.x minors and 3.x. Do not narrow to one minor with a three-segment
`~>` or commit a `path:` dependency (`CorePinConformanceTest`). Raise the floor
only for a required core API/migration. `phoenix_kit_templates` is a direct
dependency because rendering calls its substitution API.

CRM (`PhoenixKitCRM.*`) and core's Emails module are runtime soft dependencies:
guard references with `Code.ensure_loaded?/1` and call through `apply/3`
(`soft_call/3` is intentionally credo-disabled). Ecto `from`/`join` introspects
literal schema modules at compile time; a module attribute does not prevent
this. Build CRM schema atoms with `Module.concat/1` inside functions.
CRM is a test-only dependency to exercise real schemas. `required_modules/0`
returns `["emails"]`, but layouts use this package and `PhoenixKit.Email.Layout`,
not `PhoenixKit.Modules.Emails.*`.

There are no newsletters-owned mailing lists or activity logs. Audiences are
CRM lists (`"crm_list"`) or core roles (`"user_group"`); stale
`"newsletters_list"` rows/tokens must degrade without crashing. Provider events
are handled externally via `find_delivery_by_message_id/1` and
`update_delivery_status/3`.

## Commands & checks

```bash
mix deps.get
createdb phoenix_kit_newsletters_test  # once; DB tests auto-skip without it
mix test
mix format
mix precommit                        # required before every commit
```

`precommit` runs compile with warnings as errors, `deps.unlock --check-unused`,
`hex.audit`, and `quality.ci` (format check, strict Credo, Dialyzer).
`mix quality` applies formatting then runs strict Credo and Dialyzer;
`mix quality.ci` only checks formatting, so run `mix format` first.

Dependencies resolve from Hex; this repo has no `pk_dep/3` helper. To test
local core, temporarily use
`{:phoenix_kit, path: "../phoenix_kit", override: true}`, run `mix deps.get`,
and revert **both** `mix.exs` and `mix.lock` before committing.

## Web conventions

- Use `PhoenixKit.Newsletters.Paths` for module URLs;
  `PhoenixKit.Utils.Routes.path/1` for cross-module links/string paths and
  `Routes.url/1` for absolute email links. No relative email URLs or hardcoded
  hosts; route new code through `Paths`, even where old templates use literals.
- Register admin routes only through tabs' `live_view:` in `admin_tabs/0`;
  public routes only through `route_module/0` (`Web.Routes.generate/1`). Never
  hand-register them in a host router; see core's `guides/custom-admin-pages.md`.
  Admin root: `/admin/newsletters/broadcasts`, tab `:admin_newsletters`,
  priority 520, group `:admin_modules`. Child ids use `admin_newsletters_`;
  URL segments use hyphens. Tabs cover broadcasts, layouts and verification;
  new/edit/details tabs are hidden. Keep module-key callbacks and settings
  consistent with `"newsletters"`.
- Preferences has its own public `live_session` in `Web.Routes` for token
  access without login. Its dashboard tab `:dashboard_newsletters_preferences`
  uses absolute `/newsletters/preferences`, group `:account`, **no `live_view`**,
  visible only with CRM. Dashboard live_sessions require login.
- One-click unsubscribe GET/POST uses the separate
  `:phoenix_kit_newsletters_one_click` pipeline with only `accepts ["html"]`,
  outside `:browser`: RFC 8058 POSTs carry no session or CSRF token.
- LiveViews use `Phoenix.LiveView` and `use Gettext, backend:
  PhoenixKit.Newsletters.Gettext`, importing core components explicitly
  (`PhoenixKitWeb.Components.Core.{Icon, PkLink, EmptyState, TableDefault}`).
  Do not use `PhoenixKitWeb, :live_view`. Admin templates wrap in
  `PhoenixKitWeb.Components.LayoutWrapper.app_layout`; preferences uses
  `AuthPageWrapper.auth_page_wrapper`. Controllers/HTML use
  `PhoenixKitWeb, :controller` / `:html`.
- Admin assigns: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`,
  `@current_locale`, `@url_path`. Use `assign_new/3` for current user and
  tracked `@phoenix_kit_current_user` in templates; `assigns[...]` makes the
  media picker re-render on every keystroke. Never `assign(:layout, _)`:
  dead rendering reserves `:layout` for the page layout.
- Put token verification, timezone resolution and account contact find/link
  in `handle_params/3`, not `mount/3` (mount runs twice).
- Every LiveView mount checks `enabled?/0` and flashes/redirects if disabled.
  `enabled?/0` reads `newsletters_enabled` (default `false`), rescuing exceptions
  to `false` without catching `:exit`.
- Gettext backend: `PhoenixKit.Newsletters.Gettext`, locales `en`, `et`, `ru`.
  Every `Tab.new!` supplies `gettext_backend:`. Hand-list new tab labels in
  the "Sidebar tab labels" block of `priv/gettext/default.pot` (the extractor
  misses them), then `mix gettext.extract --merge`. `I18nTest` requires
  non-identity Russian translations for tab labels.
- No JS hooks currently. New hooks ship via `js_sources/0` under a namespaced
  global, never inline `<script>` (morphdom does not execute inserted scripts).
  `css_sources/0` returns `[:phoenix_kit_newsletters]`.
- Store UTC; display through `Web.Timezone.viewer_tz/1` (profile
  `user_timezone` → setting `time_zone` → `"0"`) and core's per-instant
  helpers. Use `Settings.get_timezone_label/1`, never a private timezone list.

## Permissions

Use `PhoenixKit.Newsletters.Access` (`Scope.can?/2`, never raw key membership).
The base `newsletters` key allows drafting, layouts, broadcast lists/counts.

| Permission | Enforcement |
|---|---|
| `newsletters.send` | Send/schedule in `BroadcastEditor` **before saving**; retry/cancel in `BroadcastDetails.confirm_action` |
| `newsletters.audiences` | Load delivery addresses in `BroadcastDetails`; `Verification` checks at mount **and** in its event handler; verification tab also requires it |
| `crm` | `Access.crm_lists?/1` also requires `CRMSource.available?/0`; gates offering, previewing, saving and sending a CRM audience |

Without CRM permission, editor/verification offer roles only and reject crafted
`crm_list` sources. Workers and the scheduled sweep have no viewer scope.
Admin receives sub-keys through core boot grants, Owner through `"*"`.
`migrate_legacy/0` / `PermissionBackfill` grants each sub-key once to roles
already holding the base key, using `newsletters_send_backfilled` and
`newsletters_audiences_backfilled`; set each flag only after all grants succeed
so failures retry next boot. Later base-key grants retain the narrow meaning.

## Data & rendering invariants

All table-backed schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
and `use PhoenixKit.SchemaPrefix` (`SchemaPrefixConformanceTest`). SQL uses
`uuid_generate_v7()`, never `gen_random_uuid()`.

Tables are `phoenix_kit_newsletters_{broadcasts,deliveries,layouts}`:

- `Broadcast`: `draft → scheduled → sending → sent`, plus `cancelled`, `failed`.
  `crm_list` needs `crm_list_uuid`; `user_group` needs
  `source_params["role_uuids"]`. Resolve roles by UUID, never mutable names;
  `role_names_snapshot` is display-only. Attachments: up to 10 distinct Storage
  file UUIDs in send order. `template_uuid` → layouts, `ON DELETE SET NULL`;
  `crm_list_uuid` and `send_profile_uuid` are soft references without FKs.
  `delete_broadcast/1` deletes only drafts; otherwise
  `{:error, :cannot_delete_non_draft}`. No soft-delete sentinel.
- `Delivery`: `pending` is the **only non-terminal status**; terminal statuses
  are `sent`, `delivered`, `opened`, `bounced`, `failed`, `blocked`.
  Exactly one owner: `user_uuid`, or `crm_contact_uuid` + `recipient_email`.
  `message_id` is unique.
- `Layout`: unique slug `name`; `display_name`, `subject`, `html_body`,
  `text_body` are language maps; status `active`/`archived`.
  Added/changed HTML translations must place `{{{content}}}`; an HTML edit
  must leave at least one language doing so. Added/changed subject translations
  must contain `{{subject}}`; untouched imported translations are not rechecked.
  Never cast `metadata` or `created_by_user_uuid`; `create_layout/2` takes the
  author as an option (user FK `ON DELETE SET NULL`). Imported
  `metadata["email_is_system"] == true` layouts stay archived, cannot be
  restored or made default.

New broadcasts read `newsletters_default_template`, unset by default;
the Layouts page writes it through `Layouts.set_default_layout/1`.

`Content` renders Markdown with MDEx and **always** runs
`PhoenixKit.Utils.HtmlSanitizer`. `Render` builds every email:

1. Apply layout in recipient language, inserting the body at `{{{content}}}`
   (legacy `{{content}}` supported).
2. Run **one** `PhoenixKit.Templates.Substitution` pass for `name`, `email`,
   `unsubscribe_url`, `preferences_url`, `header`, `footer`, `logo_url`,
   `accent_color`, `site_name`, `site_url`, `subject`. Double braces escape;
   triple braces insert raw. Unknown tags stay literal. Omit an unresolved
   `preferences_url` from the map so it stays literal rather than linking `/`.
3. With no layout or no body slot for that language, use core's standard
   `PhoenixKit.Email.Layout.wrap/3`, group `"newsletters"`. Never wrap text.

`RecipientLanguage.for_recipient/2` resolves user `preferred_locale` via core's
`RecipientLocale`, or CRM contact locale → list locale → site content language.
`Layout.translation/3` falls back language → base → other base dialect → site
language → any. Never hardcode `"en"`; editor language tabs use
`Layout.language_tabs/2` to map each field to its stored key.

`Render.chrome/2` calls `PhoenixKit.Email.Layout.render_parts/2`, group
`"newsletters"`: `_header-newsletters` → `_header` → core's part (same for
footer), with Branding logo/accent. Never rebuild core chrome here or read/write
`phoenix_kit_email_templates` at runtime; V2 imported its rows once.

## Sending & cancellation

- `Broadcaster.send/1` accepts `draft`, `scheduled`, `failed`. Reject a CRM
  list not `active` with `{:crm_list_not_active, status}` **before** status
  changes. Render Markdown, flip to `sending`, resolve recipients once:
  CRM subscribed/not opted out/with email, deduplicated by downcased email;
  role users active/not opted out, deduplicated by user.
- Insert batches of 500 in one transaction; enqueue one `DeliveryWorker` per
  inserted row. Correct `total_recipients` to actual row count afterwards so
  a resend never zeroes it. `insert_all` bypasses changesets:
  `process_batch/5` manually checks user UUID or email presence and relies on
  the DB owner CHECK and partial unique indexes
  `idx_newsletters_deliveries_uniq_broadcast_{user,contact,email}` with
  `on_conflict: :nothing`, **no `conflict_target`**. New recipient sources
  require corresponding DB uniqueness before use.
- Queue is **`newsletters_delivery`**, never `newsletters`; keep README host
  config consistent. Worker: `max_attempts: 3`, unique on `delivery_uuid`
  while incomplete. Profile `rate_per_hour`, `rate_per_day`, `pause_seconds`
  determine the tightest interval (`send_interval_seconds/1`); schedule job N
  at N × interval continuously across batches, 0 = all at once. Throttling is
  per broadcast; concurrent broadcasts may exceed a profile's combined caps.
  No `newsletters_rate_limit` setting exists; do not re-add it.
- Worker skips already-sent deliveries. It re-reads the broadcast and sends
  **only under `"sending"`** (`@sendable_broadcast_statuses`,
  `guard_broadcast_sendable/1`). Keep this an allow-list: new statuses must
  stall rather than accidentally send.
- **Recheck immediately before sending** (`recheck_broadcast_sendable/1`
  before `send_email/7`): recipient lookup, rendering and attachment downloads
  can take seconds. Cancellation only writes the broadcast row, leaving queued
  jobs to stop themselves; it cannot retract mail handed to the provider.
  Both status-guard skips return plain `:ok` and write **nothing** to delivery
  rows/counters. Leave them `pending`: a terminal status could finalize the
  broadcast, and `failed` would inflate bounce counts.
- Sending uses the enabled broadcast profile, else default profile, else
  legacy `PhoenixKit.Mailer.deliver_email/1`. Sender falls back to
  `from_email` / `from_name` (`noreply@example.com` / `Newsletter`). Add
  `List-Unsubscribe` and `List-Unsubscribe-Post` when a one-click URL resolves.
  Resolve attachments last; warn/drop unreadable files instead of failing.
- SMTP may return a raw receipt string. `extract_message_id/1` must **never
  raise** after provider acceptance: that would retry and duplicate email.
- Transient failures remain `pending` until retries are exhausted; early
  `failed` lets the broadcast finalize while a retry is queued. Result status,
  counter bump and finalization run in one transaction
  (`update_delivery_result/5`); finalize only when no delivery is pending.
  Permanent failures (`{:blocked, _}`, `:deleted`, `:not_configured`,
  `:unsupported_provider`, `{:invalid_smtp_port, _}`) cancel jobs without
  counter bumps. Exhausted transient failures count as bounces.
- `process_scheduled_broadcasts/0` first repairs stuck `sending` broadcasts
  with one batch UPDATE, then sends due `scheduled` broadcasts. Inactive CRM
  lists mark the broadcast `failed` (retryable), avoiding failure every tick.

## Public unsubscribe & preferences

Never mutate on GET: link scanners fetch email URLs. Tokens use `Phoenix.Token`,
endpoint `PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)`, 7-day max
age. Keep salts and claim scopes separate:

| Purpose | Salt | Claims |
|---|---|---|
| CRM list unsubscribe | `unsubscribe` | `contact_uuid`, `crm_list_uuid` |
| Role opt-out | `newsletters_user_optout` | `user_uuid` (verified as `{:role_optout, _}`) |
| Full preference center | `newsletters_preferences` | `contact_uuid` |

A per-list token must never grant full preference access.

- `GET /newsletters/unsubscribe?token=` only confirms (`:confirm`,
  `:already_unsubscribed`, `:invalid`). POST `scope=list` removes CRM list
  membership idempotently; `scope=all` opts the contact out globally;
  `scope=role_optout` calls `UserGroupSource.record_opt_out/1`, writing
  `custom_fields["newsletters_opted_out_at"]` and linked CRM `opted_out_at`.
- `GET /newsletters/unsubscribe/one-click` redirects to confirmation;
  POST performs RFC 8058 unsubscribe and always answers 200.
- `/newsletters/preferences[?token=]` grants access to the token's contact.
  Without a token, find or lazily create/link an authenticated user's contact.
  Never use `Contacts.connect_user/2`; multiple unlinked contacts sharing an
  email count as no match. Degrade gracefully when CRM is unavailable.

## Address verification

Use the same `CRMSource` / `UserGroupSource.sendable_recipients/1` resolvers as
sending. The host configures
`config :phoenix_kit_newsletters, :email_verification_engine, Module`;
there is no default or engine dependency, even for tests.

- `VerificationEngine` callbacks, batch/verdict shapes and
  `{:email_verify_batch, %{...}}` messages are a compatibility surface;
  change only additively, with new callbacks in `@optional_callbacks`.
  `EmailVerification` uses load/export checks + `apply/3` and neutral reads;
  `start_batch/4` returns `{:error, :unavailable}` or
  `{:error, {:engine_error, msg}}` for exceptions. Mask addresses in logs and
  engine-error messages. Page states: `:unavailable`, `:disabled`, `:ready`.
- Filter with `statuses_for/1` (fallback `results_for/1`); fetch full results
  only for the displayed page. Batch sources: `newsletters_crm_list` (list
  UUID) / `newsletters_user_group` (digest of sorted role UUIDs).
- Guard starts server-side: ready engine, nonempty audience, no queued/running
  batch. Run blocking `start_batch/4` via `start_async/3` / `handle_async/3`;
  `starting` disables/rejects duplicate starts. Subscribe to engine PubSub
  **before** re-reading the batch; refresh table results only when it ends.
- Optional `smtp_mode/0` / `runner_status/0` default to `"off"` / `nil`.
  Distinguish `not_sure` + `smtp_pending` ("Waiting for SMTP") from
  `smtp_disabled` ("Domain OK (no SMTP)"); show `awaiting_smtp` progress.
  While running, recheck `smtp_runner_waiting?/0` every 10 seconds. Link a
  waiting-runner hint only to optional engine `settings_path/0`: require a
  same-site absolute path without backslashes, control characters or whitespace
  (including browser host-escape forms); otherwise show plain text. There is
  no core settings-page fallback.

## Database & migrations

Read `PhoenixKitNewsletters.Migrations`' moduledoc before changing DDL. The
chain is driven by host `mix phoenix_kit.update` through `migration_module/0`.
It must work both after historical core migrations and independently on fresh
installs (core 3.0 no longer creates module tables).

- **V1 adoption:** historical core V135 plus V145/V152/V155/V156/V158 built
  broadcasts/deliveries. V1 reproduces their complete final shape and stamps
  `pknl_schema:1` on broadcasts; it is a no-op on existing shape. Guards must
  match constraints/indexes **semantically**, not just by name: renamed hosts
  keep `mailing` object names. Preserve comments/version-marker handling.
  Do not add an adoption `ADD COLUMN` / `DROP NOT NULL` safety-net section.
  Ensure UUIDv7/extension prerequisites when building independently.
  `down/1` never drops either adopted table, for any target.
- **V2 layouts:** create layouts, stamp `pknl_schema:2`, copy non-system email
  templates under the same UUIDs plus referenced system rows (always archived).
  Preserve language maps and source rows. Probe legacy table with `to_regclass`;
  use `ON CONFLICT (uuid) DO NOTHING`; resolve name collisions (8 hex, 32 hex,
  then numbered suffix), including earlier rows in the same import. Append
  `pknl_layouts:imported` to layouts' comment so cumulative replay/down-up
  never imports later templates. Removing that marker re-enables import.
  Find/drop old `template_uuid` FKs by columns/target, not names; NULL dangling
  references with NOTICEs; add `fk_newsletters_broadcasts_template` → layouts
  `ON DELETE SET NULL`. At target ≥ 2, omit V1's legacy template-FK guard so
  absent email-template tables are never resolved via `::regclass`.
- **V3 canonical names:** stamp `pknl_schema:3`; rename legacy primary keys,
  FKs and indexes to manifest names only for exactly one full semantic match
  with a free target name. NOTICE successful renames; WARNING on ambiguity or
  collisions. Do not create/drop/rewrite objects or undo renames on down.
  Keep the 5 s `lock_timeout`: constraint renames take ACCESS EXCLUSIVE locks;
  update busy hosts in a quiet window. Repair skips tables behind the chain.
- `PhoenixKit.Newsletters.ExpectedSchema` is generated: regenerate after chain
  changes using the command in its header; never hand-edit it. Validate with
  `test/integration/{expected_schema,migrations_build_alone}_test.exs`.
  For objects still audited by core, update/exclude core's manifest first and
  require that release, or repair may reject/revert the new shape. Core 2.52
  removed its old template-FK target; do not reintroduce it.
- `Broadcast.column_widths/0`, `Delivery.column_widths/0`,
  `Layout.column_widths/0` are width authorities. `recipient_email` is
  `public.citext` even with a custom table prefix. Never restore removed
  `list_uuid`, its FK or index. Adopt the retired DB default
  `source_type = 'newsletters_list'` verbatim; Ecto uses `"crm_list"`.

## Testing

- DB: `phoenix_kit_newsletters_test` + optional `MIX_TEST_PARTITION` suffix;
  `PGUSER`/`PGPASSWORD`/`PGHOST` default to `postgres`/`postgres`/`localhost`.
  `test_helper.exs` starts `Test.Repo`, migrates core, CRM and this chain,
  enables manual sandbox, PubSub manager, ModuleRegistry and dead-render
  endpoint. No reachable DB excludes `:integration`; the attachments probe
  excludes `:requires_v158` when absent. The "core V158 … not present" warning
  usually accompanies the same missing-DB condition, not a second problem.
  Builds-alone/manifest tests also skip if required core test support is absent.
- `PhoenixKitNewsletters.DataCase` tags integration tests, checks out sandbox
  and supplies `errors_on/1` and `TestScopes` (`full_scope`, `scope_with`,
  `enable_crm`). Hand-built admin sockets need `phoenix_kit_current_scope`;
  registry registration matters because `Scope.can?/2` checks module state.
- Existing LiveView tests call lifecycle/events directly; controller tests
  use cookie sessions and `fetch_flash`. These miss initial browser-render
  failures. Add every new LiveView to `test/support/dead_render_router.ex`
  and cover it in `web/dead_render_test.exs`; never use a content `:layout`
  assign (see Web conventions).
- Verification tests use `test/support/fake_verification_engine.ex` via
  application config, scripted answers and call messages. Keep it aligned
  with the behaviour. Drive async starts via `start_via_event/1`; the fake
  finds the test owner through `$callers` from the async task.
- `config/test.exs` supplies host Repo, encryption secret, Swoosh test adapter
  and a raw endpoint secret for `Phoenix.Token` without a running endpoint.
  Unit/conformance/token/content/cache tests and statement-only
  `migrations_test.exs` run without Postgres; real-DDL migration tests need it.
  Worker helpers marked `@doc false` provide direct unit-test seams.

## Commits & releases

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`,
  `Merge`). Version/CHANGELOG changes belong in the upstream release commit,
  not feature PRs.
- Review docs: `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`,
  one per reviewing agent; never edit another agent's review. `FOLLOW_UP.md`
  records resolutions. Severities: `BUG - CRITICAL/HIGH/MEDIUM`,
  `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.
- SemVer; version is single-sourced as `@version` in `mix.exs`. Release order:
  bump it; add `## x.y.z - YYYY-MM-DD` to `CHANGELOG.md`; pass `mix precommit`;
  commit (`Bump version to x.y.z`), push and verify; `mix hex.publish`;
  **only after publish succeeds**, tag and push tag. Match newest tag form
  (`git tag --sort=-creatordate | head -1`); tags are immutable. `mix docs`
  uses `source_ref: @version`, so tag/version must agree for source links.
  Create a GitHub release with `gh release create` if this repo uses them
  (check `gh release list`).

## Deferred work (do not implement incidentally)

- Suppressed deliveries stay `pending` under cancelled broadcasts; finalization
  and repair only operate on `sending`. Any reporting/resume feature reading
  pending deliveries must join broadcast status. When such a feature needs a
  terminal suppressed status, add `cancelled` with a backfill decision, excluded
  from bounce counts and `non_terminal_broadcast_uuids_query/0`; never reuse
  `failed`.
- Large cancellations still wake queued jobs to skip. Consider
  `Oban.cancel_all_jobs/1` when real send volume makes that cost material;
  retain both worker guards to close execution races.
