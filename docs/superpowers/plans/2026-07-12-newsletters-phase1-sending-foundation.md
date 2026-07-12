# Newsletters Phase 1 — Sending Foundation (Integrations + Send Settings) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the sending foundation for the expanded newsletters system — move email credentials into core PhoenixKit **Integrations** (starting with AWS SES, adding **Brevo API + SMTP** and **generic SMTP**), and add a newsletters **"Send Settings"** block (send profiles) that reference an integration and carry per-account send parameters (rate, from-name, reply-to, signature) — with multiple profiles per integration.

**Architecture:** Credentials live ONLY in core `PhoenixKit.Integrations` (JSONB rows in `phoenix_kit_settings`, sensitive fields AES-256-GCM encrypted). The `emails` module and the `newsletters` module resolve credentials from Integrations by stored UUID. All *send behavior* (cadence, identity, signatures) lives in a newsletters-owned `SendProfile` schema. Sending routes through core `PhoenixKit.Mailer` / `Email.Provider` (preserving tracking/SES behavior), selecting a Swoosh adapter per profile (SES / SMTP / Brevo API). New DB table (`send_profiles`) is created by a **core migration `V143`** (consistent with existing newsletters tables in core `V79`/`V84`).

**Tech Stack:** Elixir ~> 1.18, Phoenix LiveView ~> 1.1, Ecto (raw-SQL versioned migrations in core), Swoosh (AmazonSES / SMTP / Brevo adapters), Oban ~> 2.20, UUIDv7 PKs, Gettext, ExUnit.

**Dev/test target (confirmed):** the running dev app **inside the `phoenix_kit` container** at `/root/projects/hydroforce` (dev DB = `postgres` container; NOT prod `hydroforce_prod`/`elixir_postgres`). Modules wired via **`path:` deps** to the in-container fork checkouts (`/app`, `/root/projects/phoenix_kit_emails`, `/root/projects/phoenix_kit_newsletters`).

## Global Constraints

- **Migrations go in CORE** `phoenix_kit` (`lib/phoenix_kit/migrations/postgres/`), versioned. Current `@current_version` = **142**; next = **143**. Never `migration_module/0` for this project.
- **Credentials are stored ONLY in Integrations** (never new plaintext settings rows). Sensitive JSONB field names must be in `Encryption.@sensitive_fields` (`access_token refresh_token client_secret api_key bot_token secret_key`) to auto-encrypt.
- All new tables/columns are prefix-aware: `prefix = Map.get(opts, :prefix, "public")` + local `prefix_str/1`; every table name interpolated as `#{p}`.
- All schemas use **UUIDv7** PKs; tables named `phoenix_kit_*`.
- All new admin UI strings via the owning module's Gettext backend (`PhoenixKit.Newsletters.Gettext` / emails backend). Locales: en/et/ru.
- Quality gate per task: `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix test` — all green before commit.
- Work happens in the **forks** (`timujinne/*`), on feature branches; each Stage is a reviewable PR. **Do not push to prod or touch `hydroforce_prod`.**
- Backward compatibility: existing SES sending in `emails` must keep working throughout (legacy settings remain a fallback until B4 migrates them).

---

## Stage A — Environment & module wiring (prerequisite)

### Task A1: Confirm all three forks are updated from upstream

**Files:** none (git state only), in container repos `/app`, `/root/projects/phoenix_kit_emails`, `/root/projects/phoenix_kit_newsletters`.

- [ ] **Step 1: Verify sync**
Run (in `phoenix_kit` container):
```bash
for r in /app /root/projects/phoenix_kit_emails /root/projects/phoenix_kit_newsletters; do
  cd "$r"; git fetch upstream -q
  echo "$r: $(git rev-list --left-right --count main...upstream/main)"
done
```
Expected: each prints `0\t0` (0 ahead / 0 behind). Core was fast-forwarded to `1.7.186` (@current_version 142); emails/newsletters already 0/0.

- [ ] **Step 2:** If any is behind, `git checkout main && git merge --ff-only upstream/main && git push origin main`. (Core already done.)

### Task A2: Wire the three forks into the dev app via `path:` deps and boot with migrations

**Files:**
- Modify: `/root/projects/hydroforce/mix.exs` (deps block)

**Interfaces:**
- Produces: a running dev app at `:4000` (container) using `phoenix_kit` (path `/app`), `phoenix_kit_emails` (path `/root/projects/phoenix_kit_emails`), `phoenix_kit_newsletters` (path `/root/projects/phoenix_kit_newsletters`), migrated to core V143-ready baseline.

- [ ] **Step 1: Back up and edit deps** — in `/root/projects/hydroforce/mix.exs`, set:
```elixir
{:phoenix_kit, path: "/app", override: true},
{:phoenix_kit_emails, path: "/root/projects/phoenix_kit_emails"},
{:phoenix_kit_newsletters, path: "/root/projects/phoenix_kit_newsletters"},
```
(Replace the current hex/github forms for these three. Keep other deps unchanged.)

- [ ] **Step 2: Fetch/compile**
Run: `mix deps.get && mix deps.compile phoenix_kit --force && mix compile`
Expected: compiles clean.

- [ ] **Step 3: Apply PhoenixKit + Ecto migrations against dev DB**
Run: `mix phoenix_kit.update && mix ecto.migrate && mix phoenix_kit.status`
Expected: status reports current version 142 (pre-V143), no pending errors.

- [ ] **Step 4: Boot & smoke**
Run: `MIX_ENV=dev elixir --sname hfdev -S mix phx.server` (or restart the existing `iex -S mix phx.server`); open `/phoenix_kit/admin` — newsletters + emails modules load; enable Newsletters in Admin → Modules.
Expected: app boots; both modules' admin tabs visible.

- [ ] **Step 5: Commit** (in hydroforce dev checkout, feature branch):
```bash
git checkout -b feature/newsletters-sending-foundation
git add mix.exs mix.lock && git commit -m "chore(dev): wire phoenix_kit/emails/newsletters forks via path deps for sending-foundation work"
```

---

## Stage B — AWS SES credentials → Integrations (emails refactor)

> No DB migration needed — Integrations are JSONB rows in `phoenix_kit_settings`. This stage registers an `aws_ses` provider, points the emails getters at Integrations, and migrates existing plaintext SES settings into an encrypted Integrations connection.

### Task B1: Register the `aws_ses` integration provider (core)

**Files:**
- Modify: `/app/lib/phoenix_kit/integrations/providers.ex` (add to `builtin_providers/0`, ~line 124)
- Test: `/app/test/phoenix_kit/integrations/providers_test.exs`

**Interfaces:**
- Produces: provider key `"aws_ses"`, `auth_type: :key_secret`, setup fields `access_key_id`, `secret_key`, `aws_region`. (Field **`secret_key`** deliberately named to hit `Encryption.@sensitive_fields` so it auto-encrypts.)

- [ ] **Step 1: Write failing test**
```elixir
test "aws_ses provider is registered with encryptable secret field" do
  p = PhoenixKit.Integrations.Providers.get_provider("aws_ses")
  assert p.auth_type == :key_secret
  keys = Enum.map(p.setup_fields, & &1.key)
  assert "access_key_id" in keys and "secret_key" in keys and "aws_region" in keys
  assert "secret_key" in PhoenixKit.Integrations.Encryption.sensitive_fields()
end
```
- [ ] **Step 2: Run → FAIL** (`get_provider("aws_ses")` returns nil). Run: `mix test test/phoenix_kit/integrations/providers_test.exs`
- [ ] **Step 3: Implement** — add to `builtin_providers/0` (follow the OpenAI map shape at `providers.ex:248-322`):
```elixir
%{
  key: "aws_ses", name: "Amazon SES", description: "AWS Simple Email Service (SMTP credentials via SES API)",
  icon: "hero-envelope", auth_type: :key_secret,
  setup_fields: [
    %{key: "access_key_id", label: "Access Key ID", type: :text, required: true, placeholder: "AKIA…"},
    %{key: "secret_key",    label: "Secret Access Key", type: :password, required: true},
    %{key: "aws_region",    label: "Region", type: :text, required: true, placeholder: "eu-central-1"}
  ],
  capabilities: ["email_send"]
}
```
- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** (`/app`): `feat(integrations): register aws_ses provider`

### Task B2: Resolve SES credentials from Integrations in the emails module

**Files:**
- Modify: `/root/projects/phoenix_kit_emails/lib/.../emails.ex` (`get_aws_access_key/0` ~2171, `get_aws_secret_key/0` ~2189, `get_aws_region/0` ~1286)
- Add: a helper `aws_ses_credentials/0` in the same module
- Test: emails fork `test/.../aws_credentials_test.exs`

**Interfaces:**
- Consumes: `PhoenixKit.Integrations.get_credentials/1` (`{:ok, map}`), setting `emails_aws_integration_uuid`.
- Produces: getters that return Integrations creds when an integration is selected, else fall back to the legacy `Settings.get_setting("aws_*")` values (backward compat until B4).

- [ ] **Step 1: Write failing test** — with an `aws_ses` connection saved and `emails_aws_integration_uuid` set, `get_aws_access_key/0` returns the Integrations value, not the legacy setting.
```elixir
test "get_aws_access_key prefers the selected Integrations connection" do
  {:ok, uuid} = seed_aws_ses_integration(%{"access_key_id" => "AKIA_NEW", "secret_key" => "S", "aws_region" => "eu-central-1"})
  PhoenixKit.Settings.update_setting("emails_aws_integration_uuid", uuid)
  assert PhoenixKit.Modules.Emails.get_aws_access_key() == "AKIA_NEW"
end
```
- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** the helper + rewire getters (keep legacy fallback):
```elixir
defp aws_ses_credentials do
  case PhoenixKit.Settings.get_setting("emails_aws_integration_uuid") do
    uuid when is_binary(uuid) and uuid != "" ->
      case PhoenixKit.Integrations.get_credentials(uuid) do
        {:ok, creds} -> creds
        _ -> %{}
      end
    _ -> %{}
  end
end

def get_aws_access_key,  do: Map.get(aws_ses_credentials(), "access_key_id") || legacy_aws_access_key()
def get_aws_secret_key,  do: Map.get(aws_ses_credentials(), "secret_key")    || legacy_aws_secret_key()
def get_aws_region,      do: Map.get(aws_ses_credentials(), "aws_region")     || legacy_aws_region()
```
(`legacy_*` = the current `Settings.get_setting("aws_access_key_id")`/… bodies, renamed.)
- [ ] **Step 4: Run → PASS**; also assert legacy fallback still works when no UUID set.
- [ ] **Step 5: Commit** (emails fork): `feat(emails): resolve AWS SES creds from Integrations with legacy fallback`

### Task B3: Emails admin — select an `aws_ses` integration

**Files:**
- Modify: emails settings LiveView `/root/projects/phoenix_kit_emails/lib/.../web/settings.ex` (+ its heex): add an "SES credentials source" selector listing `aws_ses` connections (`Integrations.list_connections("aws_ses")`), writing the chosen UUID to `emails_aws_integration_uuid`; keep the legacy fields visible but marked "legacy — migrate to Integrations".
- Test: LiveView test that selecting a connection persists `emails_aws_integration_uuid`.

- [ ] **Step 1–5:** TDD the selector (failing LiveView test → implement `handle_event("select_aws_integration", …)` → pass → commit `feat(emails): choose SES Integrations connection in settings`).

### Task B4: `Emails.migrate_legacy/0` — move plaintext SES settings into an encrypted Integrations connection

**Files:**
- Modify: emails module — implement the `migrate_legacy/0` behaviour callback (currently defaulted).
- Test: emails fork migration test.

**Interfaces:**
- Consumes: legacy settings `aws_access_key_id`/`aws_secret_access_key`/`aws_region`; `Integrations.add_connection/3`, `Integrations.save_setup/3`.
- Produces: an `aws_ses` connection populated from legacy values; `emails_aws_integration_uuid` set; runs idempotently.

- [ ] **Step 1: Write failing test** — given legacy AWS settings and no integration, `migrate_legacy/0` creates one `aws_ses` connection, sets `emails_aws_integration_uuid`, and re-running does nothing.
- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement**
```elixir
@impl PhoenixKit.Module
def migrate_legacy do
  if Settings.get_setting("emails_aws_integration_uuid") in [nil, ""] do
    ak = Settings.get_setting("aws_access_key_id"); sk = Settings.get_setting("aws_secret_access_key")
    if is_binary(ak) and ak != "" and is_binary(sk) and sk != "" do
      {:ok, uuid} = Integrations.add_connection("aws_ses", "Amazon SES (migrated)")
      {:ok, _} = Integrations.save_setup(uuid, %{
        "access_key_id" => ak, "secret_key" => sk,
        "aws_region" => Settings.get_setting("aws_region") || "us-east-1"
      })
      Settings.update_setting("emails_aws_integration_uuid", uuid)
    end
  end
  :ok
end
```
- [ ] **Step 4: Run → PASS** (assert secret is stored `enc:v1:`-prefixed in the JSONB row).
- [ ] **Step 5: Commit** (emails fork): `feat(emails): migrate_legacy moves SES creds into encrypted Integrations`

### Task B5: Live-test SES-via-Integrations on Hydra Force

- [ ] **Step 1:** In the running dev app, run `PhoenixKit.Modules.Emails.migrate_legacy()` (via `mix phoenix_kit.update` legacy hook or IEx), confirm an `aws_ses` connection appears at `/admin/settings/integrations` with an encrypted secret.
- [ ] **Step 2:** Send a test email (emails module test-send) and confirm delivery via SES using Integrations-sourced creds; verify the legacy plaintext row is no longer the source (temporarily blank it to prove).
- [ ] **Step 3:** Record result in the PR description. No code commit (verification only).

---

## Stage C — Brevo (API + SMTP) and generic SMTP providers + send abstraction

### Task C1: Register `brevo_api`, `brevo_smtp`, and `smtp` providers (core)

**Files:** Modify `/app/lib/phoenix_kit/integrations/providers.ex`; Test `providers_test.exs`.

**Interfaces (verified Brevo facts):**
- `brevo_api`: `auth_type: :api_key`, field `api_key` (format `xkeysib-<64hex>-<16>`; **not** the SMTP `xsmtpsib-` key), `base_url: "https://api.brevo.com/v3"`.
- `brevo_smtp`: `auth_type: :credentials`, fields `username` (`<subacct>@smtp-brevo.com`), `password` (`xsmtpsib-…` → store under `secret_key`? No — SMTP password field must encrypt; name it `password` and extend `@sensitive_fields`, OR store as `api_key`). **Decision:** extend `Encryption.@sensitive_fields` with `"password"` (Task C2) so SMTP passwords encrypt. host `smtp-relay.brevo.com`, port `587` as defaults.
- `smtp` (generic): `auth_type: :credentials`, fields `host`, `port`, `username`, `password`.

- [ ] **Steps:** failing test asserting the three providers + their fields → implement provider maps (Brevo API/SMTP defaults per verified facts) → pass → commit `feat(integrations): register brevo_api, brevo_smtp, smtp providers`.

### Task C2: Encrypt SMTP passwords — extend sensitive fields

**Files:** Modify `/app/lib/phoenix_kit/integrations/encryption.ex` (`@sensitive_fields`, line 20-23); Test `encryption_test.exs`.

- [ ] **Step 1: Failing test** — `encrypt_fields(%{"password" => "xsmtpsib-x"})` returns an `enc:v1:`-prefixed value; `decrypt_fields` round-trips.
- [ ] **Step 2: FAIL** — [ ] **Step 3:** add `"password"` to `@sensitive_fields`. — [ ] **Step 4: PASS** — [ ] **Step 5: Commit** `fix(integrations): encrypt smtp password field`.
> Also fix the moduledoc PBKDF2→SHA-256 inaccuracy in the same commit (doc-only).

### Task C3: Swoosh delivery selection per integration provider (core mailer seam)

**Files:**
- Modify: `/app/lib/phoenix_kit/mailer.ex` — add `swoosh_config_for/1` mapping an integration provider+creds → `{adapter, config}` (AmazonSES / SMTP / Brevo). Keep routing through `deliver_email/2` so `Email.Provider.intercept_before_send/handle_after_send` still fires.
- Test: core mailer test with `Swoosh.Adapters.Test`.

**Interfaces:**
- Produces: `PhoenixKit.Mailer.deliver_via_integration(email, integration_uuid, opts)` → resolves creds via `Integrations.get_credentials/1`, builds adapter config, delivers through the existing interceptor path.
- Adapter map: `"aws_ses"→Swoosh.Adapters.AmazonSES`, `"smtp"|"brevo_smtp"→Swoosh.Adapters.SMTP`, `"brevo_api"→Swoosh.Adapters.Brevo` (api_key).

- [ ] **Steps:** failing test (each provider builds the expected adapter config and delivery is captured by `Swoosh.Adapters.Test`) → implement `swoosh_config_for/1` + `deliver_via_integration/3` → pass → commit `feat(mailer): deliver via a chosen Integration (SES/SMTP/Brevo)`.
> Confirm `Swoosh.Adapters.Brevo` is available (add `{:swoosh, …}` already present; Brevo adapter ships with Swoosh). If absent, use a thin `POST /v3/smtp/email` client via `Integrations.authenticated_request/4`.

### Task C4: Live-test Brevo API + SMTP on Hydra Force

- [ ] Add a `brevo_api` connection (real `xkeysib` key from `~/.config/brevo.env`) and a `brevo_smtp` connection; send a test email each via `deliver_via_integration/3`; confirm 201 (API) / accepted (SMTP). Record results. (Mind the ~300/rolling rate limit.)

---

## Stage D — Newsletters "Send Settings" (SendProfile) + sender wiring

### Task D1: Core migration V143 — `phoenix_kit_newsletters_send_profiles`

**Files:**
- Create: `/app/lib/phoenix_kit/migrations/postgres/v143.ex`
- Modify: `/app/lib/phoenix_kit/migrations/postgres.ex` (`@current_version 142 → 143`; move `⚡ LATEST` moduledoc marker)
- Test: core migration test (up creates table + sets comment '143'; down drops + '142').

**Interfaces:**
- Produces table `phoenix_kit_newsletters_send_profiles`: `uuid` (PK, uuid_generate_v7), `name`, `integration_uuid` (references the Integrations settings row UUID — stored as UUID, no FK since integrations live in `phoenix_kit_settings.key`), `provider_kind` (aws_ses|smtp|brevo_api|brevo_smtp), `from_name`, `from_email`, `reply_to`, `signature_html`, `signature_text`, `rate_per_hour` (int), `rate_per_day` (int), `pause_seconds` (int), `advanced` (jsonb, per-type extras: SES queue/config-set, etc.), `enabled` (bool), `inserted_at`, `updated_at`.

- [ ] **Step 1: Write failing migration test** (run `V143.up` on a test prefix, assert table exists + `COMMENT ON TABLE …phoenix_kit IS '143'`).
- [ ] **Step 2: FAIL**
- [ ] **Step 3: Implement `v143.ex`** (follow `v79.ex` raw-SQL pattern):
```elixir
defmodule PhoenixKit.Migrations.Postgres.V143 do
  use Ecto.Migration
  def up(opts) do
    p = prefix_str(Map.get(opts, :prefix, "public"))
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_send_profiles (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      integration_uuid UUID NOT NULL,
      provider_kind VARCHAR(40) NOT NULL,
      from_name VARCHAR(255), from_email VARCHAR(255), reply_to VARCHAR(255),
      signature_html TEXT, signature_text TEXT,
      rate_per_hour INTEGER, rate_per_day INTEGER, pause_seconds INTEGER DEFAULT 0,
      advanced JSONB NOT NULL DEFAULT '{}'::jsonb,
      enabled BOOLEAN NOT NULL DEFAULT TRUE,
      inserted_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )""")
    execute("CREATE INDEX IF NOT EXISTS idx_nl_send_profiles_integration ON #{p}phoenix_kit_newsletters_send_profiles(integration_uuid)")
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '143'")
  end
  def down(opts) do
    p = prefix_str(Map.get(opts, :prefix, "public"))
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_send_profiles CASCADE")
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '142'")
  end
  defp prefix_str("public"), do: "public."
  defp prefix_str(nil), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
```
- [ ] **Step 4: PASS**; bump `@current_version` to 143. — [ ] **Step 5: Commit** (`/app`): `feat(migrations): V143 newsletters send_profiles table`

### Task D2: `SendProfile` Ecto schema + context (newsletters)

**Files:**
- Create: `/root/projects/phoenix_kit_newsletters/lib/phoenix_kit/newsletters/send_profile.ex`
- Modify: newsletters context `newsletters.ex` (CRUD: `list_send_profiles/0`, `get_send_profile!/1`, `create_send_profile/1`, `update_send_profile/2`, `delete_send_profile/1`)
- Test: `send_profile_test.exs`

**Interfaces:**
- Produces: `PhoenixKit.Newsletters.SendProfile` schema mirroring the V143 columns; changeset validates `name`, `integration_uuid`, `provider_kind ∈ ~w(aws_ses smtp brevo_api brevo_smtp)`, non-negative rates.

- [ ] **Step 1: Failing changeset test** (required fields; provider_kind inclusion; multiple profiles may share one `integration_uuid`).
- [ ] **Step 2: FAIL** — [ ] **Step 3:** implement schema (UUIDv7 PK, `schema "phoenix_kit_newsletters_send_profiles"`, fields per D1, `timestamps(type: :utc_datetime)`) + context CRUD (via `RepoHelper.repo()`). — [ ] **Step 4: PASS** — [ ] **Step 5: Commit** `feat(newsletters): SendProfile schema + context`.

### Task D3: Newsletters admin — "Send Settings" LiveView

**Files:**
- Create: `lib/phoenix_kit/newsletters/web/send_profiles.ex` (+ `.html.heex`) and `send_profile_editor.ex` (+ heex)
- Modify: `newsletters.ex` `admin_tabs/0` — add a "Send Settings" tab (+ hidden new/edit) following the existing `Tab.new!` pattern (icon `hero-paper-airplane`, gettext backend).
- Test: LiveView tests (list renders; create profile selecting an integration + rate/signature persists).

**Interfaces:**
- Consumes: `Integrations.list_connections/1` for each email-capable provider to populate the integration picker; `Newsletters` SendProfile CRUD.
- Produces: admin routes `newsletters/send-settings`, `.../new`, `.../:id/edit`.

- [ ] **Steps:** failing LiveView test → implement list + editor (integration dropdown grouped by provider; fields: name, from_name, from_email, reply_to, signature_html/text, rate_per_hour/day, pause_seconds, advanced JSON per kind) → pass → commit `feat(newsletters): Send Settings admin (send profiles)`.

### Task D4: Route the newsletters sender through a SendProfile → integration

**Files:**
- Modify: `lib/phoenix_kit/newsletters/workers/delivery_worker.ex` `send_email/4` — instead of the single `PhoenixKit.Mailer.deliver_email/1`, resolve the broadcast's chosen `SendProfile`, apply `from_name`/`reply_to`/signature, and deliver via `PhoenixKit.Mailer.deliver_via_integration/3` (Task C3).
- Modify: `broadcast.ex` + V143? No — add `send_profile_uuid` to broadcasts. **Column add → fold into V143** (add `ALTER TABLE …phoenix_kit_newsletters_broadcasts ADD COLUMN IF NOT EXISTS send_profile_uuid UUID`) and the `Broadcast` schema/changeset.
- Test: worker test asserting the email is built with the profile's identity and delivered via the profile's integration adapter (`Swoosh.Adapters.Test`).

**Interfaces:**
- Consumes: `Newsletters.get_send_profile!/1`, `Mailer.deliver_via_integration/3`.
- Produces: per-broadcast send-method selection; signature appended to body; from/reply-to from the profile.

- [ ] **Steps:** update V143 to add `send_profile_uuid` to broadcasts (before Stage D ships) → failing worker test → implement profile-aware `send_email/4` (fallback to legacy single-Mailer when no profile) → pass → commit `feat(newsletters): send broadcasts via selected Send Profile/integration`.

### Task D5: Live-test end-to-end on Hydra Force

- [ ] Create two Send Profiles on the SAME Brevo integration (different from_name + rate), attach one to a small test broadcast to a user list, send, and confirm: correct From/signature, delivery via Brevo, and that the second profile is independently usable. Record results in the PR.

---

## Self-review checklist (run before requesting review)

1. **Spec coverage:** migrations-in-core-V143 ✓ (D1); forks→Hydra Force via path deps ✓ (A2); AWS creds→Integrations ✓ (B1–B5); Brevo API+SMTP + generic SMTP ✓ (C1–C4); Integrations = keys only, settings elsewhere ✓ (SendProfile D1–D4); multiple profiles per integration ✓ (D2 test, D5); per-type advanced settings ✓ (`advanced` jsonb). **Deferred (flagged):** Contacts import (arbitrary addresses) = a LATER phase, not here.
2. **Placeholder scan:** replace any `…`/legacy-body references with the real current function bodies when implementing (B2 `legacy_*`).
3. **Type consistency:** `provider_kind` values `~w(aws_ses smtp brevo_api brevo_smtp)` used identically in D1/D2/C3; `emails_aws_integration_uuid` setting key consistent B2/B3/B4.
4. **Ambiguity:** SMTP password encryption resolved by extending `@sensitive_fields` (C2); Brevo API vs SMTP are distinct providers/keys (C1).

## Open questions for reviewers
- Should generic `smtp` and `brevo_smtp` be one provider (host/port free) or two (Brevo defaults prefilled)? Plan assumes Brevo-SMTP as a convenience preset of generic SMTP.
- `send_profile_uuid` on `broadcasts` vs a global default profile — plan adds per-broadcast selection with a fallback; confirm.
- Rate enforcement (`rate_per_hour/day`, `pause_seconds`) is *stored* here but *enforced* in the later throttling phase (Phase 4/5 of the v2 spec). Confirm we defer enforcement.
