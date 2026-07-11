# PhoenixKit Newsletters — Expansion Design Spec (v2)

**Date:** 2026-07-11 · **Module:** `phoenix_kit_newsletters` (fork `timujinne` → upstream `BeamLabEU`), currently **v0.1.4**
**Goal:** Grow the module from a basic opt-in broadcast tool into a full-featured mailing system with feature parity to **LetsExtract Email Studio 7** (the desktop bulk-mailer used on the laptop), while staying a compliant, web-native PhoenixKit module.

**v2 note:** revised after two independent **GLM-5.2** plan reviews (roles: `component-architect` + `reviewer`, `--effort max`), whose load-bearing claims were verified against the parent `phoenix_kit` codebase. The reviews reshaped the domain model and phases — see **Appendix B**.

---

## 1. Locked decisions

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Recipient model | **Hybrid** — keep registered-user subscriptions AND add importable **Contact** lists of arbitrary emails | user |
| 2 | Sending backend | **Multi-account sending** — several SMTP "send methods" with signatures, rotation, per-account limits | user |
| 3 | Deliverable now | **Design spec + phased plan**, stop for user review before implementation | user |
| 4 | Plan review | Reviewed by **GLM-5.2** agents (via `phoenix_kit` container `zai … --model glm-5.2 --effort max`) | user |
| 5 | SMTP credential storage | **Reuse `PhoenixKit.Integrations` + `Integrations.Encryption` (AES-256-GCM)** — no bespoke crypto, no Cloak | GLM review (verified) |
| 6 | New tables home | **Ship via `migration_module/0`** (package-owned versioned migrations), NOT parent core migrations | GLM review (verified) |
| 7 | Tracking path | **Reuse `PhoenixKit.Email.Provider` hooks**; multi-account sends must still funnel through the Mailer/Provider seam | GLM review (verified) |

---

## 2. Upstream sync status (verified)

Inside the `phoenix_kit` container at `/root/projects/phoenix_kit_newsletters`:
- `origin` = `timujinne/phoenix_kit_newsletters` (fork) · `upstream` = `BeamLabEU/phoenix_kit_newsletters` (canonical)
- Local `main` ↔ `origin/main` ↔ `upstream/main`: **0 ahead / 0 behind — fully synced.** Version 0.1.4.

Expansion branches from this clean, synced `main`. (Spec committed on `feature/newsletters-expansion-spec`.)

---

## 3. Current module (v0.1.4) — what exists today

**Schemas** (UUIDv7 PKs, tables `phoenix_kit_newsletters_*`; created today in **parent core** migrations `v79`/`v84`, renamed by `20260316205415_rename_mailing_to_newsletters`):
- `List` — name, slug, description, status, is_default, subscriber_count
- `ListMember` — membership of a **registered user** (`user_uuid` → `Users.Auth.User`), status, subscribed/unsubscribed_at
- `Broadcast` — subject, markdown/html/text body, status, scheduled_at, sent_at, counters, `template_uuid` (→ **Emails.Template**, optional), one `list_uuid`
- `Delivery` — per-recipient tracking; **`user_uuid` is `validate_required`** (delivery.ex:52) and NOT NULL

**Send pipeline:** `Broadcaster.send/1` streams active `ListMember.user_uuid` → batches of 500 → `insert_all` Delivery rows + `Oban.insert_all` `DeliveryWorker` jobs, **all inside one `repo.transaction`**. `DeliveryWorker` (queue `newsletters_delivery`) renders `{{name}}/{{email}}/{{unsubscribe_url}}`, optionally wraps in an Emails template, and sends via the single host `PhoenixKit.Mailer.deliver_email/1` (which resolves one `Email.Provider.current()` and injects runtime config — SES branches included). Throttle = Oban queue concurrency (`newsletters_rate_limit`, default 14/s). `process_scheduled_broadcasts/0` exists.

**Hard constraints today (the crux):**
1. A recipient *is* a registered user; arbitrary emails cannot exist.
2. `DeliveryWorker`, the unsubscribe **token** (`%{user_uuid, list_uuid}`), and the `UnsubscribeController` are all **user-bound**.
3. New tables have **no package-owned migration path** — the module never implements `migration_module/0`.

---

## 4. LetsExtract → module gap map

Legend: ✅ exists · ⚠️ partial · ❌ missing. (Verified LetsExtract terminology; full inventory in **Appendix A**.)

| LetsExtract capability | Today | Work needed |
|---|---|---|
| Import lists **from files** (CSV/XLSX = email+fields; TXT = email-only) | ❌ | `Contact` + importer (fields → macros) |
| Import **from clipboard/paste** (one/line) | ❌ | Paste importer + parse/dedup |
| Working with / segmenting lists | ⚠️ user only | Extend to contact lists |
| **Black list / suppression** (email; role-prefix) | ❌ | `Suppression` subsystem, enforced enqueue+send |
| **Templates** (multiple, HTML+text, upload/EML) | ⚠️ one optional Emails template | Module-owned `Template` library |
| **Macros** `%Var%` (+ spintax) | ⚠️ 3 hardcoded `{{}}` | Macro engine (`%Var%` **and** `{{var}}`); spintax = optional/cut |
| **Attachments** (files, inline/URL images) | ❌ | Reuse parent **Storage** module + Swoosh attach |
| **Multiple send methods** (SMTP profiles) | ❌ single Mailer | `SendMethod` + **Integrations** creds |
| Per-method **From/Reply-to/ReturnPath**, signature | ⚠️ single from_email/name | Fields on `SendMethod` |
| **Rotation** + per-account limits | ❌ | Rotation + atomic per-method caps |
| **"Check SMTP"** test | ❌ | Admin test-send action |
| **Spam-check** (SpamAssassin 0–10, mail-tester, DNSBL) | ❌ | Optional Phase 7 (defer) |
| **Preview** (browser / .eml) + **test send** | ✅ preview | Add test-send + .eml preview |
| **Send speed** (batch=N + Pause(s) + Connections) | ⚠️ Oban concurrency | Rate/window design (Phase 5) |
| **Scheduling** | ⚠️ scheduled_at + scheduler | Extend scheduler |
| **Reports** (delivered/opened/clicks/bounces/unsub) | ⚠️ counters | Reuse `Email.Provider` + tracking routes |
| Address **verification** | ❌ | Future Phase 9 |

> Notes: LetsExtract suppression is **email-level "Black list"** (+ role-prefix `abuse@`); **domain/pattern blocklists are our enhancement**, beyond parity. Per-account **signature** is our addition (unverified in LetsExtract).

---

## 5. Target domain model (revised per review)

New/changed schemas (all `phoenix_kit_newsletters_*`, UUIDv7) — **all shipped via the package's own `migration_module/0`**:

- **`Contact`** — `email` **(citext, GLOBAL unique per tenant-`prefix`; migration must `CREATE EXTENSION IF NOT EXISTS citext`)**, first/last name, company, country, `custom_fields` (jsonb → macros), status (active/bounced/unsubscribed/complained), source. Independent of `Users`. Membership expressed **only** via `ContactListMember` (no "scope" ambiguity).
- **`ContactListMember`** — join `contact_uuid` ↔ `list_uuid`, status. (Existing `ListMember` for users stays → hybrid.)
- **`List` change** — no `kind` enum. A list may hold both user and contact members; the Broadcaster resolves recipients by **UNION** of the two joins. (`kind` dropped — it would drift from actual membership. Optional creation *hint* only, if ever.)
- **`Delivery` changes** — add nullable `contact_uuid`; make `user_uuid` **nullable**; **DB `CHECK ((user_uuid IS NULL) <> (contact_uuid IS NULL))`** (changeset-only XOR is insufficient — `Broadcaster` uses `insert_all`, bypassing changesets). Add `send_method_uuid`, open/click fields.
- **`Suppression`** — `type` (email/domain/pattern), `value`, `scope` (global/list), reason, source. Enforcement: email+domain as a **single set-membership query** at enqueue; patterns a **bounded** pass; **worker guard is the source of truth** (catches suppressions added post-enqueue).
- **`Template`** — module-owned library (name, subject, html/text, macros meta). **Resolve `Broadcast.template_uuid` collision** (today → Emails.Template): split into `emails_template_uuid` vs `newsletter_template_uuid`, or model polymorphic `{type, uuid}`. Decided in Phase 0.
- **`SendMethod`** — **thin** row: from_name, from_email, reply_to, return_path, signature_html/text, enabled, hourly_limit, daily_limit, rotation weight/priority, optional headers (List-ID/List-Unsubscribe/Precedence), **`integration_uuid` FK → `PhoenixKit.Integrations`** (which holds the encrypted SMTP/API secret). **No bespoke encrypted-config column.**
- **`SendMethodUsage`** — per-method per-window counter; enforced with an **atomic claim** (`UPDATE … SET used = used+1 WHERE used < cap RETURNING`, row-lock) or a per-method rate-limiter — because Oban's **global** queue concurrency cannot express per-account caps.
- **`Attachment`** — belongs to broadcast/template; **store via parent `PhoenixKit.Storage`** (not module-local); Swoosh attach.
- **`Campaign`** — **cut from v1** (drip/staged = different product). Single-shot scheduling stays on `Broadcast.scheduled_at`.

**Sender-pipeline refactor (the real unlock):** `Broadcaster` resolves user∪contact recipients and writes `user_uuid` XOR `contact_uuid` deliveries (+ **unique index `(broadcast_uuid, user_uuid)` / `(broadcast_uuid, contact_uuid)`** for idempotency; move the long-running enqueue **out of one giant transaction** into per-batch txns for 100k+ scale). `DeliveryWorker` becomes **recipient-agnostic** (user OR contact: to-address, macro vars, and a **contact-capable unsubscribe token**). Multi-account send still routes through `Mailer.deliver_email/2` (per-call Swoosh config from the SendMethod) to **keep Provider/tracking/SES behavior** — not a raw per-account Swoosh mailer that bypasses it.

---

## 6. Subsystems (isolation boundaries)

1. **Migrations** — package `migration_module/0` + versioned skeleton (`phoenix_kit_update_v*_to_v*`).
2. **Contacts** — CRUD + file/clipboard import + dedup + segmentation.
3. **Sender pipeline** — recipient-agnostic Broadcaster/Worker + contact unsubscribe + idempotency.
4. **Suppression** — check(email/domain/pattern) enforced at enqueue + worker.
5. **Templates** — library CRUD, upload/EML, macro engine (`%Var%`+`{{}}`), HTML-escaped merge fields.
6. **Sending accounts** — `SendMethod` (+Integrations) + rotation + atomic per-method limits, via Mailer/Provider seam.
7. **Throttling & scheduling** — batch/pause/window → Oban design; extend `process_scheduled_broadcasts`.
8. **Attachments** — parent Storage + Swoosh attach.
9. **Spam-check** *(optional/deferrable)* — SpamAssassin/mail-tester/DNSBL.
10. **Tracking & reporting** — `Email.Provider` hooks + open/click routes + webhook ingestion.

---

## 7. Phased roadmap (revised)

Every phase ends green (compile + credo + dialyzer + tests incl. the invariants named below) and is a reviewable PR. Dependencies drove the resequencing.

- **Phase 0 — Architecture & migration plumbing (blocker for all).** Implement `migration_module/0` → `PhoenixKit.Newsletters.Migrations` (versioned). Lock three decisions: (i) SMTP creds via **Integrations** (`integration_providers/0` contributes `smtp`/provider defs); (ii) tracking reuses **`Email.Provider`**; (iii) resolve **`template_uuid`** collision (split/polymorphic). No feature code.
- **Phase 1a — Contacts foundation.** `Contact` + `ContactListMember` schemas, contacts CRUD LiveView, **import from CSV/XLSX (email+fields) and TXT/clipboard**, parse + dedup + validate. Ships as "manage contact lists" (does **not** yet send to them — honest scope).
- **Phase 1b — Send-to-contacts (pipeline refactor).** Nullable `Delivery.user_uuid` + `contact_uuid` + **DB CHECK XOR**; `Broadcaster` UNION resolution + **idempotency unique index** + per-batch txns; recipient-agnostic `DeliveryWorker`; **contact-capable unsubscribe token** + controller branch; **union-aware `count_active_members`/`subscriber_count`**. *This* unlocks arbitrary-address mailing. Backward-compat test: existing user lists send identically.
- **Phase 2 — Suppression / block-lists.** `Suppression` (email/domain/pattern; our domain/pattern enhancement), admin UI, enforcement at enqueue (set-membership) + **worker guard as source of truth**; auto-add on user unsubscribe now, on bounce/complaint when Phase 8 lands.
- **Phase 3 — Template library + macros.** Module `Template` (multiple, HTML+text, visual+raw, upload/**EML**), macro engine `%Var%`+`{{var}}` with **HTML-escaped** merge fields; broadcast selects template. *(Spintax: optional, likely cut v1.)*
- **Phase 4 — Multi-account sending + limits** *(merged with old Phase 5's limit half)*. `SendMethod` (thin + `integration_uuid`; From/Reply-to/ReturnPath/signature/headers), **"Check SMTP"**, **rotation**, **atomic per-method hourly/daily caps** (`SendMethodUsage`), routed through `Mailer.deliver_email/2`. Design the Oban model (dynamic per-method queues or app-level limiter) — the single shared queue can't do per-account caps.
- **Phase 5 — Pacing & scheduling.** Map **batch=N + Pause(s) + Connections(threads)** onto the enqueue timing; send windows; extend `process_scheduled_broadcasts`. (Rotation/limits already correct from Phase 4.)
- **Phase 6 — Attachments.** Parent **Storage**-backed attachments (any number); Swoosh attach; inline vs linked images.
- **Phase 7 — Spam-check & test-send** *(optional, cut-candidate; must not block critical path)*. SpamAssassin 0–10 + mail-tester + DNSBL; .eml/browser preview; test send.
- **Phase 8 — Tracking & reports.** Open pixel + click redirect **routes** (`route_module` additions) via `Email.Provider` hooks; bounce/complaint webhook ingestion (Brevo) → `Delivery`/`Suppression`; unsubscribe modes; per-broadcast/campaign analytics.
- **Phase 9 (future) — Address verification.** Email Verifier (~10 criteria) feeding list hygiene. Out of v1.

**Cut from v1 (YAGNI):** `Campaign`/drip-staged sends, spintax, and (deferred) spam-check. Live email harvesting/crawling stays in the LetsExtract crawler toolkit. A/B testing excluded.

---

## 8. Integration points & conventions

- **Migrations:** package-owned via `migration_module/0`, run by `mix phoenix_kit.update` (naming `phoenix_kit_update_v*_to_v*`).
- **Credentials:** `PhoenixKit.Integrations` + `Integrations.Encryption` (`enc:v1:` AES-256-GCM); `migrate_legacy/0` for any local→Integrations moves.
- **Mailer/Provider:** all sends (incl. multi-account per-call config) go through `PhoenixKit.Mailer` → `Email.Provider.intercept_before_send/handle_after_send` so tracking/SES behavior is preserved.
- **Oban:** `newsletters_delivery` queue; add per-method limiting (dynamic queues or app-level limiter) + a scheduler cron; **broadcast-level idempotency** via delivery unique indexes.
- **Storage:** attachments via parent `PhoenixKit.Storage`.
- **Admin tabs / Settings / gettext:** extend `Tab.new!` set (Contacts, Suppression, Templates, Send Methods, Reports) and `route_module/0` (unsubscribe-contact, open-pixel, click-redirect); strings via `Newsletters.Gettext` (locales en/et/ru).
- **Compliance:** every send path enforces suppression + unsubscribe; keep the opt-in user path unchanged; imports carry a lawful-basis note.

---

## 9. Risks / open questions (post-review)

- **Answered by codebase:** SMTP encryption → Integrations.Encryption (no Cloak). Attachment storage → parent Storage. Tracking → Email.Provider.
- **Open:** Oban per-method concurrency model (dynamic queues vs app-level limiter) — decide in Phase 4. `template_uuid` split vs polymorphic — decide in Phase 0. Spam-check provider (self-host vs API) — only if Phase 7 is taken. Bounce/complaint webhooks (Brevo) — Phase 8. Deliverability/legal positioning for cold imports (suppression + rate limits mitigate).

---

## Appendix A — LetsExtract Email Studio 7 sender: verified feature inventory

- **Recipients**: import CSV/XLSX (email + Name/Company/City/Age/Gender/Address) and TXT/clipboard (email only); manual add / paste one-per-line; multiple named lists, merge, rule-based move; statuses **Subscribed + Activated** required. *Dedup control unverified.*
- **Black list**: permanent, non-deletable suppression by **email**; role-prefix filter (`abuse@`, `forspam@`); bounce-manager auto-removal. *Domain/regex blocklists NOT in LetsExtract.*
- **Templates**: Blank/Template, ships templates, save your own; visual HTML + raw toggle; plain-text checkbox; macros `%Name% %Company% %Date% %site% %UNSUBSCRIBE%`; **spintax** `{a|b|c}` + random text; **EML** import/export.
- **Attachments**: any number, saved in project; images from local file or URL.
- **SMTP profiles**: Server/Port/login(+app password), **"Check SMTP"** test; **Sender/Reply-to/ReturnPath**; **SMTP Rotation**; SendGrid/Mailgun/TurboSMTP/etc; optional headers **List-ID/List-Unsubscribe/Precedence: Bulk**. *Per-account signature unverified.*
- **Spam check**: **SpamAssassin 0–10** color-coded + **mail-tester.com** (3/day) + standalone **DNSBL** (20+).
- **Preparation**: preview "In browser" (HTML/TXT) / "In email client" (.eml); **test send**.
- **Sending/throttling**: **Sending Mode** all-at-once / **batch (e.g. 100)** + **Pause Between Sending (seconds)** + **Connections (threads)**; marketed no fixed cap. *Explicit per-account numeric limits partially verified.*
- **Scheduler**: schedule when a mailing sends, pace to server. *Recurrence/window/drip unverified.*
- **Reports**: delivered/opened/complaints/errors/unsubscribes/clicks; Google Analytics; unsubscribe modes link/browser/email; bounce-manager via ReturnPath. *Open-pixel/click mechanism undocumented.*
- **Email Verifier (integrated)**: ~10 criteria (syntax, MX, mailbox SMTP handshake), statuses feed lists.

**Sources:** letsextract.com/email-sender/ · /email-sender-manual.htm · /docs/email_sender.htm · /docs/email_recipients.htm · /docs/creating_an_email.htm · /docs/smtp_settings.htm · /email-verifier/ · /dnsbl-checker/ · SMTP-limits blog (2025-10-02). (Deep pages sending/scheduler/reports were IP-blocked; `docs/user-manual.pdf` best closes remaining gaps.)

---

## Appendix B — GLM-5.2 review synthesis

Two independent GLM-5.2 reviews (`component-architect`, `reviewer`; `--effort max`) read this plan **and the actual parent `phoenix_kit` code**. Verdicts: *Needs-rework* and *Sound-with-changes*. All load-bearing claims below were re-verified by me against the deps tree.

**Critical / adopted into v2:**
1. **No migration home** → implement `migration_module/0`; ship tables in-package (Phase 0). *(module.ex:112; newsletters implements none.)*
2. **`SendMethod` reinvented Integrations** → reuse `Integrations` + `Integrations.Encryption` (AES-256-GCM, `enc:v1:`); `SendMethod` = thin row + `integration_uuid`. No Cloak (absent from lockfile).
3. **Phase 1 "unlocks mailing" was false** → split into 1a (contacts) + 1b (pipeline refactor: nullable `user_uuid`, XOR CHECK, Broadcaster UNION, recipient-agnostic worker, contact unsubscribe token). *(delivery.ex:52 validate_required; worker user-bound.)*
4. **Multi-account bypasses Mailer/Provider** (tracking + SES) → route per-call through `Mailer.deliver_email/2`; Swoosh per-call config is enough (no per-account module). *(Email.Provider callbacks exist.)*
5. **Per-method limits ≠ global Oban concurrency** → atomic usage-claim; merge limits into Phase 4; add **broadcast idempotency** unique index (Broadcaster currently can duplicate deliveries; insert_all + Oban.insert_all in one txn can orphan rows).

**Also adopted:** `template_uuid` collision (split/polymorphic); drop `List.kind`/resolve by UNION; `Contact.email` global-unique + citext extension; union-aware counters; macro HTML-escaping; parent `Storage` for attachments; suppression enforcement performance; long-enqueue-transaction scale fix; `route_module` additions; explicit backward-compat + concurrency tests. **YAGNI cuts:** Campaign/drip, spintax, spam-check (defer/cut v1).
