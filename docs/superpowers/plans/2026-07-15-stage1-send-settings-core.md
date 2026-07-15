# Stage 1 — Send Settings → Core (+ Stage 2 quota surfacing) — Implementation Plan

**Date:** 2026-07-15 · **Spec:** `../specs/2026-07-15-restructuring-global-spec.md` §5 + Stage 2
**Process:** subagent-driven (implementer → 2-stage reviewer per task, fix cycles direct); live-test checkpoints with the user after CP1 and CP2; Workflow-based multi-lens final review at stage end.
**Repos:** core `/app` (branch off current work), `phoenix_kit_emails`, `phoenix_kit_newsletters` — all path-wired into `/root/projects/hydroforce` (hot-reload on).

## Naming decisions (locked here so tasks don't drift)

- Core schema: `PhoenixKit.Email.SendProfile`; context: `PhoenixKit.Email.SendProfiles`; options: `PhoenixKit.Email.ProviderOptions` — the `PhoenixKit.Email.*` namespace already hosts the Provider seam.
- Table: `phoenix_kit_email_send_profiles` (same columns/indexes as V145's newsletters table, incl. the `is_default` partial unique index; `integration_uuid` stays NOT NULL — profiles are Integration-only per spec).
- Settings key: `default_email_integration_uuid`.
- Module-behaviour seam: `email_settings_sections/0` (default `[]`), collected by `ModuleRegistry.all_email_settings_sections/0`.
- Core migration: next free version at implementation time (V151 as of writing — verify `@current_version` first).

## Track A — sequential (core ← emails ← newsletters lockstep)

### A1 (core): SendProfile schema + context + ProviderOptions in core
Port `PhoenixKit.Newsletters.SendProfile` (schema incl. `valid_provider_kinds/0` from `Providers.with_capability(:email_send)` and the provider-kind-matches-integration validation), the send-profile context functions from `PhoenixKit.Newsletters` (list/get/create/update/delete/get_default/set_default), and `PhoenixKit.Newsletters.ProviderOptions` (whole module + its test suite) into core under the names above, table name `phoenix_kit_email_send_profiles`. Pure port — no behavior changes. Tests ported alongside (core test conventions). Newsletters is NOT touched in this task.

### A2 (core): migration V151 — create, copy, drop
New versioned migration (next free number): create `phoenix_kit_email_send_profiles` (DDL mirroring `v145.ex` table incl. indexes), `INSERT … SELECT` all rows from `phoenix_kit_newsletters_send_profiles` **preserving uuids**, then `DROP TABLE` the newsletters one. `down`: recreate the newsletters table, copy back, drop the core one. `broadcasts.send_profile_uuid` is a bare UUID (no FK) — untouched. Bump `@current_version`. DO NOT run the migration on the dev DB in this task — it runs at CP1 after A3, so running code and schema switch together.

### A3 (newsletters): re-point to core
Replace all uses of `PhoenixKit.Newsletters.SendProfile`/`ProviderOptions`/context send-profile functions with the core modules (delivery_worker, broadcaster's `send_interval_seconds` input, broadcast_editor's profile picker, send_profiles/send_profile_editor LiveViews **removed** — the UI moves to core in A4; admin tab entries for Send Settings removed from `newsletters.ex`). Delete the newsletters schema/context-functions/ProviderOptions + their tests (equivalents now live in core from A1). Keep `broadcasts.send_profile_uuid` semantics identical. Constraint bump: newsletters requires core >= the V151 release.

**CP1 (user live test):** run migration on dev DB; verify existing 6 profiles visible via core context, broadcast send via profile works end-to-end (Tidewave checks + a real test send).

### A4 (core): Settings → Emails page + Send Profiles UI + seam + default transport
1. Core admin settings page "Emails" (path `emails` under admin settings): sections — sender identity (from_name/from_email settings form; note they're read-with-fallback today, no seeded defaults), transport panel (static Swoosh app-config detected? list email-capable integrations + validation state), default integration picker writing `default_email_integration_uuid`, generic **test send** button.
2. `email_settings_sections/0` callback in `PhoenixKit.Module` (+ registry collector + render slot on the page, honoring per-section permission).
3. Send Profiles subpage (list + editor) ported from the removed newsletters LiveViews, wired to core context; per-provider `ProviderOptions` fields as before.
4. `deliver_email/2` routes through `deliver_via_integration/3` when `default_email_integration_uuid` is set (and the integration resolves); falls back to the built-in path otherwise.

### A5 (emails): single-tab convergence
Remove the module's own "Emails" settings tab registration (`emails.ex:918` area) and its duplicated sender-identity form; contribute tracking/SQS/retention sections via `email_settings_sections/0` instead (per-section permission preserved). The module's tracked test-send stays as its section.

**CP2 (user live test):** one "Emails" settings tab with module sections present; profile editor works from core UI; default-integration routing verified via a real send; emails tracking still logs sends.

## Track B — parallel (independent)

### B1 (core): integration quota/credits surfacing (spec Stage 2)
`Integrations.Validators.aws_ses/1`: stop discarding the `GetSendQuota` payload — return `{:ok, note}` with Max24HourSend/SentLast24Hours (respect the existing scoped-credentials note path). Add a `brevo_api` clause to `do_validate` (`integrations.ex:977` area) calling `GET /account`, parsing `plan[]`/`credits` into `{:ok, "N emails left …"}`. Existing `record_validation/2` → `validation_status` → live UI needs no changes. Tests for both parsers (fixture JSON).

## Final gate

Workflow-orchestrated multi-lens review of the full Stage-1 diff (correctness / security / migration-safety / UI-permission lenses, adversarial verify) → fix what's confirmed → user acceptance → GLM-5.2 pass when Z.AI recovers.
