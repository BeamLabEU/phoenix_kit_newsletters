# Ecosystem Restructuring — Global Spec (v1)

**Date:** 2026-07-15 · **Status:** DECIDED — all open questions resolved with the user 2026-07-15; adversarially reviewed (see §9); pending one external GLM-5.2 review pass (service outage at the time)
**Scope:** `phoenix_kit` (core), `phoenix_kit_newsletters`, `phoenix_kit_crm`, `phoenix_kit_emails`
**Supersedes (partially):** `2026-07-11-newsletters-expansion-design.md` (v3) — see §2 for the mapping. Phase 1 of that spec (Sending Foundation) is COMPLETE and is the foundation this builds on.

## 1. Direction (user decisions, 2026-07-15)

1. **Newsletters' own lists are removed.** Recipient source for a broadcast becomes a choice:
   - a **CRM contact list** (new subsystem in `phoenix_kit_crm`), or
   - a **core user group** = **roles** (user decision 2026-07-15: no new group entity — roles serve as groups; arbitrary marketing segmentation of people belongs in CRM lists, and a "custom set of users" is expressible by importing/syncing them into a CRM list rather than by a parallel grouping system).
2. **Send settings move to core.** The `send_profiles` table leaves newsletters entirely. Base email sending (identity, default integration, test send) must work **without the emails module** and **without Amazon** — via the default Swoosh path or any configured Integration. Static config/env credentials (the classic Swoosh config) remain a valid transport and must be **detected and displayed** alongside Integrations.
3. **Settings → Emails = ONE expandable tab in core.** Core owns the page with base sections; the emails module injects extra sections (tracking, SQS, retention) when loaded — new seam analogous to `PhoenixKit.Email.Provider`. Send Profiles = a subpage in the same zone.
4. **Templates move to core**, with four workstreams (T1–T4, §6): core move, multilingual per the Publishing model, first-class composition, module template packs.
5. **Provider analytics:** deliverability statistics and account/quota data must work for Brevo (API) as well as SES; Brevo transactional webhooks are unsigned → **polling** via `/smtp/statistics/events` is the primary ingestion path.
6. **Process:** every block is discussed (logically, visually, conceptually) before implementation; GLM-5.2 agent reviews at each level; live testing on the Hydra Force dev app with the user after key stages.

## 2. Relationship to the v3 expansion spec

| v3 element | Fate in this spec |
|---|---|
| Phase 1 Sending Foundation (Integrations providers, `deliver_via_integration`, SendProfile, blocklist E1/E2) | **DONE** (core 1.7.190; PRs merged/pending). Kept as the foundation. |
| Phase 2 Contacts (`Contact` + `ContactListMember` **inside newsletters**, hybrid user∪contact lists, UNION resolution) | **SUPERSEDED**: contacts/lists live in **CRM**; hybrid lists replaced by explicit recipient-source choice (CRM list XOR user group per broadcast). No mixed lists. |
| Delivery XOR `CHECK ((user_uuid IS NULL) <> (contact_uuid IS NULL))` at DB level (insert_all bypasses changesets) | **CARRIED OVER** (contact side now references CRM contact). |
| Idempotency unique indexes `(broadcast_uuid, user_uuid)` / `(broadcast_uuid, contact_uuid)` | **CARRIED OVER**. |
| Per-batch transactions instead of one giant enqueue txn (100k+ scale) | **CARRIED OVER**. |
| Recipient-agnostic `DeliveryWorker`; contact-capable unsubscribe token | **CARRIED OVER** (member-scoped token). |
| Phase 3 Suppression: unify with emails blocklist, never build a third system | **CARRIED OVER** unchanged. |
| Phase 4 newsletters-owned Template library; `template_uuid` collision (emails vs newsletters templates) | **SUPERSEDED** by templates→core: ONE system, collision disappears. Macro engine (`%Var%`+`{{var}}`, HTML-escaped) carried over. |
| Phase 5 Rotation & atomic per-profile caps (`SendProfileUsage`, `UPDATE … WHERE used < cap RETURNING`) | **CARRIED OVER as a later stage**: the current `schedule_in` throttle (PR #15 follow-up) is per-broadcast only; cross-broadcast caps need the atomic claim design. |
| Phase 6 Attachments via parent Storage | **CARRIED OVER** (unchanged, later stage). |
| Phase 7 Tracking: "Brevo webhook ingestion" | **CORRECTED**: Brevo webhooks are unsigned → poll `/smtp/statistics/events` (90-day retention, 2 RPS) through the existing Oban pattern. |
| Import CSV/XLSX (email+fields), TXT/clipboard (email-only), paste one-per-line | **CARRIED OVER** into CRM list import. |
| Migrations in core versioned migrations (V143+ convention) | **CARRIED OVER** — all new DDL ships in core `vNNN.ex`, next free number at implementation time. |

## 3. Stage plan

- **Stage 0 — Prerequisites.** Newsletters PR #15 merged; CRM `feature/crm-party-roles` merged (ships SchemaPrefix + the pattern lists build on); CRM connected to Hydra Force (core ≥ V140); `crm_contacts.email` → **citext, nullable, NON-unique** + plain index (see §4 — uniqueness deliberately NOT imposed).
- **Stage 1 — Core "Settings → Emails" + Send Profiles in core.** §5.
- **Stage 2 — Integration quota/credits surfacing.** Validators already call SES `GetSendQuota` and Brevo `GET /account` but discard payloads; return `{:ok, note}` (mechanism exists: `record_validation/2` → `validation_status` → live UI). Structured storage (`connection_meta`) optional.
- **Stage 3 — CRM contact lists.** §4.
- **Stage 4 — Newsletters on new recipient sources.** §7.
- **Stage 5 — Brevo event source.** Extract a provider-agnostic "apply normalized event" layer from `sqs_processor.ex` (SES-specific parsing stays outside); Brevo Oban poller mapping events ~1:1 onto existing `Log.status`/`Event.event_type` enums; aggregated dashboard from `/smtp/statistics/aggregatedReport`.
- **Stage 6 — Templates in core.** §6.

Stages (1+2) and 3 can run in parallel; 4 needs 1 and 3; 5 and 6 are independent.

## 4. CRM contact lists (Stage 3)

### 4.1 Schemas (core migration, next free version)

**`phoenix_kit_crm_lists`**: uuid PK (UUIDv7), name, slug (unique), description, status (active/archived), subscriber_count (cached), metadata jsonb, timestamps. *(No `is_default` — user decision: list choice is always explicit per broadcast.)*

**`phoenix_kit_crm_list_members`**: uuid PK, list_uuid (FK → crm_lists, ON DELETE CASCADE), contact_uuid (FK → crm_contacts), **email (citext, denormalized snapshot of the contact's email at add-time)**, status (subscribed/unsubscribed/pending), subscribed_at, unsubscribed_at, source (manual/import/form/api), metadata jsonb (consent details: IP, date, text), timestamps. Constraints: **UNIQUE (list_uuid, contact_uuid)** AND **UNIQUE (list_uuid, email) WHERE email IS NOT NULL** — the second is what actually enforces per-list email uniqueness (review finding: with the always-create-new-contact import policy, two parallel imports of the same address get different contact_uuids, so an app-level check alone is racy and the contact-keyed index never fires). The app-level pre-check remains as UX (friendly "already in this list" message), not as the guarantee. If a contact's email is edited later, memberships are re-synced best-effort in the same operation; a sync that would collide with the unique index is left as-is and surfaces on the comparison screen (§4.4).

Context modelled on `PhoenixKitCRM.PartyRoles` (subscribe/unsubscribe/subscribed?/list_members). Counter maintenance: `subscriber_count` is updated by the context functions themselves (subscribe/unsubscribe/import batch) and broadcast over the existing CRM PubSub for live UI — named here explicitly so the cache has an owner.

### 4.2 Contact email semantics (user decisions)

- `crm_contacts.email`: **citext, nullable, NON-unique.** A supplier contact without email is legal; several contacts may share one mailbox. A contact without email is simply unsendable (skipped with a counter, never an error). Today the column is a plain varchar (`contact.ex:46`); the change requires `CREATE EXTENSION IF NOT EXISTS citext` + `ALTER COLUMN … TYPE citext` in a **core** versioned migration (CRM tables are core-owned, V138 convention) — not in the CRM repo.
- **Within one list an email must be unique** (user decision): enforced by the **DB unique index on the denormalized member email** (§4.1). Emails MAY repeat across different lists.
- Contact gains a **`locale`** field (drives per-recipient template language, §6).
- **Unsubscribe/consent live on the CONTACT, not on the membership** (user decision 2026-07-15): the fields developed for newsletters lists — unsubscribed/opt-out, consent agreement details — move to `crm_contacts` as contact-level state (a marketing opt-out is global for the person, which is also the legally safer semantic). Membership `status` keeps only composition semantics: subscribed / `pending` (double opt-in) / removed-from-list; the send path checks BOTH (member subscribed AND contact not opted out).
- **Double opt-in**: schema-ready NOW (`pending` status + confirm token in metadata); the working confirmation-email flow is a planned stage, not part of the first cut (user decision).

### 4.3 Import (built from scratch — exists nowhere today)

- Formats: **CSV + XLSX** (email + name/company/locale/custom fields), **TXT/clipboard paste** (email-only, one per line) — parity with the v3 gap map.
- **Import NEVER blocks on duplicates.** Policy (user decision): **every imported row creates a NEW contact**; no silent merging into existing contacts. Matching/deduplication is done later, read-only, on the comparison screen (§4.4). Rationale: gluing memberships to shared contacts creates unclear ownership when a list is deleted.
- **Row processing order (fixes the orphan-contact hazard):** contact INSERT and membership INSERT happen **in one transaction per row (or per chunk)**; a violation of `UNIQUE (list_uuid, email)` rolls the transaction back, so the skipped row leaves **no orphan contact** behind. Re-importing a 50k list therefore does NOT double `crm_contacts`. The in-file duplicate check and the "already in this list" check run first as cheap pre-filters, but the constraint is the guarantee.
- **Acknowledged cost of "always new contact":** `crm_contacts` is the shared CRM directory, and distinct lists importing overlapping audiences DO accumulate same-email contacts there by design. The comparison screen (§4.4) is the visibility tool; a manual "merge contacts" tool is a possible later addition and nothing in this schema blocks it.
- Within-list email uniqueness also protects `unsubscribed` members from silent resubscription by re-import (the unsubscribed member holds the email slot).
- Import report: created / added / skipped (already in list, unsubscribed, no email, invalid email, duplicate within file).
- Manual single-entry form: email + name + locale, same pipeline, live "already in this list" hint.
- **Never** use CRM's legacy `find_or_create_user_by_email` (creates placeholder core users with random passwords) in any list flow.

### 4.4 Comparison ("сличение") screen

Read-only reports, no auto-actions:
1. **Across the CRM directory**: contacts sharing the same email (the by-design accumulation from §4.3, plus membership emails that drifted from an edited contact email). *(Within-list duplicates are impossible once the §4.1 unique index exists, so the earlier "within a list" report is redefined to this.)*
2. **Across lists**: overlap of two or more lists (who is in both), counts + table.

### 4.5 Migration of existing newsletters lists

Each newsletters list → crm_list (same slug). Each member: find-or-create Contact from `user.email` + user soft-link, membership preserves status/dates. **Guard:** the link is set directly to the already-existing user — do NOT route through `Contacts.connect_user/2`, which internally calls `find_or_create_user_by_email` and would silently register a placeholder core user if none existed (`contacts.ex:235-236`). Link only to existing users; never register. Delivery history stays in newsletters (§7 adds `recipient_email` snapshot).

## 5. Core "Settings → Emails" + Send Profiles (Stage 1)

- New core settings page **Emails** with base sections: sender identity (from_name/from_email — today **read** via `Settings.get_setting` with a Config fallback at `mailer.ex:471/489`, NOT seeded in the core defaults map, and their only UI lives in the emails module), **default send transport** (App config / a chosen Integration — new `default_email_integration_uuid` setting; `deliver_email/2` routes through it when set), transport detection panel (static Swoosh config present? which email-capable Integrations connected + their validation state), **test send** button (generic core version; emails module's tracked test remains its extension).
- **Extension seam:** core page asks the module registry for extra section components (new callback, e.g. `email_settings_sections/0`, returning section components with per-section permissions); emails module contributes tracking/SQS/retention sections → ONE tab, expandable. **Critically (review finding): the emails module today registers its own routable "Emails" settings tab** (`emails.ex:918`, `Tab.new!(id: :admin_settings_emails, …, permission: "emails")`, collected by `ModuleRegistry.all_settings_tabs/0`) — that tab registration is **removed** in the same change and converted into `email_settings_sections/0` contributions, otherwise the admin gets TWO "Emails" tabs. Note the callbacks are not interchangeable shapes: `settings_tabs/0` yields routable pages, sections yield components rendered inside the core page — the section struct must carry the `permission` the old tab had.
- **Send Profiles → core** (`phoenix_kit_email_send_profiles`, new core migration — core `@current_version` is **150**, so this lands at **V151+**): fields as today (name, integration_uuid, provider_kind, from_name/from_email/reply_to, signature_html/text, rate_per_hour/rate_per_day/pause_seconds, advanced jsonb via `ProviderOptions`, enabled, is_default partial-unique). **Profiles are Integration-only** (user decision 2026-07-15): the static app-config Swoosh transport is NOT a profile option — it is **detected and displayed** on the settings page as "host mailer present/available" and remains the implicit fallback when nothing else is configured; the primary source of transports is the Integrations list (`/admin/settings/integrations`). This keeps `integration_uuid NOT NULL` (matching V145 `v145.ex:35`) and makes the data migration a **pure copy**: `INSERT … SELECT` preserving UUIDs — `broadcasts.send_profile_uuid` is a bare UUID with no FK (V145 deliberate design), so broadcasts keep working with zero re-pointing — then drop `phoenix_kit_newsletters_send_profiles`. `PhoenixKit.Newsletters.ProviderOptions` moves to core alongside.
- Settings-key ownership formalized: base sending keys = core; `aws_*`/`sqs_*` tracking keys = emails module.

## 6. Templates in core (Stage 6)

- **T1 — Move.** Schema/context/UI from emails → core (table `phoenix_kit_email_templates` is ALREADY core-owned, migration V15 — no table move). Auth/magic-link templates become fully core. `Email.Provider` template callbacks keep working; emails module keeps only its tracking-specific extensions.
- **T2 — Multilingual (Publishing model).** Replace per-locale JSON-map columns with **row-per-language** `phoenix_kit_email_template_translations` (template_uuid, language, subject, html_body, text_body, unique(template_uuid, language)). The data migration itself is mechanical, but the **blast radius is three repos in lockstep** (review finding): the map shape is known to the emails `Template` schema, `get_translation/2`, the Provider template callbacks (`provider.ex:15-17`), and call sites in core+emails+newsletters (`delivery_worker.ex:177`, `broadcast_editor.ex:282,283,293` — three hardcoded `"en"` sites, not two) — plan a coordinated release. Rendering resolves: recipient locale → template default language → en. Recipient locale sources: `crm_contacts.locale` (new, §4.2) and — **found ready-made, do NOT add a new field** — `users.custom_fields["preferred_locale"]`: full core API exists (`Auth.update_user_locale_preference/2` auth.ex:1566, validator user.ex:373-389, auto-registered field definition), and the fill path is already live in the host (language-switcher click → core `phoenix_kit_set_locale` hook → saved; hooks attached in all core on_mount variants). Gotchas: it stores a dialect code ("en-GB") → normalize via `DialectMapper.extract_base/1`; it fills only on an explicit switcher click, so most users are nil → the fallback chain is mandatory (preferred_locale → subscription/site default → en); the emails module's `Templates.get_translation/3` already implements exact→base→default fallback (template.ex:180-194). One broadcast can thus deliver each recipient their own language. **Expectation-setting:** pre-existing users and imported contacts have NULL locale until backfilled, so early multilingual broadcasts degrade to template-default/en for most recipients — the capability arrives immediately, the audience data catches up gradually.
- **T3 — First-class composition** (does NOT exist today — current "composition" is one wrapper with a `{{content}}` literal + send-profile signature). Model: template `kind` (layout/partial/content); a content template references header/footer **partials by slug**; resolution at render, per-language. (Generic `{{partial:slug}}` includes rejected for v1 — harder UI, same outcome for the actual use case.)
- **T4 — Module template packs.** Module declares `template_pack/0` (callback style of `settings_tabs/0`); core seeds on module enable: **seed-if-missing by slug, never overwrite user edits**; list shows source module (metadata.source_module exists); "Reset to default" per packaged template; module disable does NOT delete templates (delivery history may reference them). Pack versioning ("new factory version available") deferred — schema does not block it.
- Macro engine from v3 Phase 4 (both `%Var%` and `{{var}}`, HTML-escaped merge fields) lands here.

## 7. Newsletters on new recipient sources (Stage 4)

- `Broadcast` gets a **recipient source**: `source_type` (crm_list | user_group) + `source_uuid` (crm list) / `source_params` (role selection). Own `list_uuid` and the lists/list-members UI + tables are **removed** (after data migration §4.5).
- `Delivery`: `user_uuid` → nullable; add `crm_contact_uuid` (soft reference — CRM tables have no FK from newsletters); **DB CHECK XOR**; add **`recipient_email` snapshot** (citext, write-time, per the CRM `party_snapshot` pattern) so history survives contact/user deletion; idempotency unique indexes per recipient kind; per-batch txns. **Plus `UNIQUE (broadcast_uuid, recipient_email)`** (review finding): the per-recipient idempotency indexes cannot stop the same ADDRESS twice when two contacts share a mailbox, and a preflight-only dedup is defeated by parallel batches — the address-level unique index (inserts with ON CONFLICT DO NOTHING) makes send-time dedup a DB guarantee, and the conflicting delivery is recorded/reported as `duplicate`.
- `DeliveryWorker`: recipient-agnostic (email from the Delivery snapshot; variables from contact or user); unsubscribe token **person-scoped** (user decision 2026-07-15: opt-out/consent live on the person, not on a group or membership — §4.2).
- **Subscription preference center (user decision 2026-07-15 — supersedes the `newsletters_user_optouts` proposal, which is dropped):** a dedicated view (not a modal), reachable two ways — by a logged-in user from account navigation, and **from any email via a signed token without login** (one-click unsubscribe must never require a password). CRM lists gain a **`subscribable` flag**; the view shows all subscribable lists as toggles (subscribed / available-to-join) plus an **"unsubscribe from all"** action. A logged-in user gets a **lazily linked contact** (created on their first preference action, linked to the existing user — never a placeholder registration), so user subscriptions ARE ordinary CRM memberships — one subscription model for everyone. "Unsubscribe from all" = the contact-level opt-out (§4.2). Role-sourced broadcasts: the unsubscribe link lands on the same view; recipient resolution for role sources excludes users whose linked contact is opted out. Opt-out therefore has exactly ONE home (the contact) for both source kinds. Scope: the opt-out suppresses newsletters (list- and role-sourced); transactional/auth mail is outside newsletters and unaffected (the emails blocklist remains the hard-suppression layer).
- **Send-time dedup by address** (user decision): within one broadcast an address receives ONE email — enforced by the unique index above; preflight shows "N members: M sendable, K no email, L unsubscribed, D duplicate addresses".
- CRM becomes a **required dependency for CRM-list sources only**: user-group broadcasts work without the CRM module (soft-dep resolver, StaffLink pattern).
- Cross-broadcast per-profile caps (atomic `SendProfileUsage` claim) remain a LATER stage (v3 Phase 5) — the current `schedule_in` spacing is per-broadcast only.

## 8. Open questions (for review + user)

*(Answered 2026-07-15 and folded into the text: user groups = roles, no new entity (§1); opt-out/consent = contact-level, not membership (§4.2); double opt-in = schema now, flow as a planned stage (§4.2); no `is_default` (§4.1); user locale via `users.custom_fields`, no core migration (§6 — pending the existing-storage sweep); app_config = detect-and-display only, profiles are Integration-only (§5).)*

**All resolved (2026-07-15):**
1. User-group unsubscribe target → subscription preference center over subscribable CRM lists with lazily-linked contacts (§7); `newsletters_user_optouts` dropped.
2. Template T2 row-per-language over map-columns → **confirmed** (data migration + three-repo lockstep, §6).
3. Re-subscription after a global opt-out → **allowed**, from the same preference view (it is exactly where re-consent happens); re-enabling an individual list clears nothing else — the global opt-out lifts only by the person's own explicit action there.

## 8a. Dev environment (user tasks 2026-07-15)

- **Wire the CRM fork** into the Hydra Force dev app: `{:phoenix_kit_crm, path: "/root/projects/phoenix_kit_crm"}` in mix.exs (pulls `phoenix_kit_comments` transitively); host DB is at **V143**, core fork at **V150** → generate + run `phoenix_kit_update_v143_to_v150` (V145 send_profiles DDL is `IF NOT EXISTS` — idempotent over the table that already exists from the old numbering); restart the dev server so the module registers.
- **Auto-recompile of wired forks**: extend the existing dev endpoint setting `reloadable_apps: [:phoenixkit_hello_world]` (config/dev.exs:65) with `:phoenix_kit, :phoenix_kit_emails, :phoenix_kit_newsletters, :phoenix_kit_crm` — Phoenix's code reloader then recompiles a fork's changed files on the next request, no server restart.

## 9. Review log

- 2026-07-15: adversarial review by an independent reviewer agent (full text kept in session log). Verdict: **Sound-with-changes overall; §4 and §7 Needs-rework — both reworked in this revision.** Fixes applied: §4.1 denormalized member email + `UNIQUE (list_uuid, email)` (app-level check was racy under always-new-contact policy); §4.3 one-txn-per-row import (no orphan contacts) + explicit shared-directory growth acknowledgement; §4.4 within-list report redefined (impossible under the new index) to directory-wide duplicates; §4.5 connect_user placeholder-user guard; §5 emails module's own "Emails" settings tab (`emails.ex:918`) removed/converted to sections (double-tab hazard), from_name/from_email wording corrected (read-with-fallback, not seeded), V145 `integration_uuid NOT NULL` relaxation named; §6 three-repo lockstep + NULL-locale degradation notes, third `"en"` hardcode site; §7 user-group opt-out model proposed + `UNIQUE (broadcast_uuid, recipient_email)` + subscriber_count ownership (§4.1). GLM-5.2 review pending (Z.AI 529 at the time; retry scheduled).
