I now have a complete, evidence-grounded picture of both the plan and the actual module + parent PhoenixKit conventions. Let me write the review.

---

# Plan Review: Newsletters Expansion Design Spec

**Reviewer:** component-architect / module-architect
**Spec:** `docs/superpowers/specs/2026-07-11-newsletters-expansion-design.md`
**Ground truth read:** `lib/phoenix_kit/newsletters/*` (v0.1.4) + parent `phoenix_kit` behaviour, migrations, Integrations, Mailer, Email.Provider.

This is a strong, well-structured spec at the *capability* level. The gap analysis (§4) is honest and the subsystem decomposition (§6) is sound. But at the *integration* level it repeatedly under-specifies how new schemas actually attach to the existing module, and it reinvents two parent subsystems that already exist. Findings below are ordered by impact.

---

## 1. Architecture fit with PhoenixKit module conventions

### CRITICAL — Schema migrations have no declared home (the plan is silent)
The newsletters package ships **zero migrations**. Its four tables are created inside the **parent** library as core versions `V79` and `V84` (`deps/phoenix_kit/lib/phoenix_kit/migrations/postgres/v79.ex`, `v84.ex`; parent `@current_version` is `111`). The module file `lib/phoenix_kit/newsletters/newsletters.ex` does **not** implement the `migration_module/0` callback.

This is the single most important omission in the plan. §5 blithely lists **8+ new tables** (`Contact`, `ContactListMember`, `Suppression`, `Template`, `Attachment`, `SendMethod`, `SendMethodUsage`, `Campaign`) plus ALTERs to `List`/`Broadcast`/`Delivery` — and never says where the migrations live. For an **external** module (separate fork → upstream package), piggybacking on core `V112+` couples this fork to an unreleased `phoenix_kit` and defeats the point of being external.

The behaviour already provides the escape hatch — `PhoenixKit.Module.migration_module/0` (`deps/phoenix_kit/lib/phoenix_kit/module.ex:80-82, 112, 269`):
> "When set, `mix phoenix_kit.update` will automatically run this module's migrations alongside the core PhoenixKit migrations."

**Required plan change:** Add a Phase 0 / cross-cutting decision — newsletters must now implement `migration_module/0` returning a new `PhoenixKit.Newsletters.Migrations` versioned module, and *all* new tables ship there. This is a hard prerequisite for Phase 1, not a detail to discover mid-implementation.

### MAJOR — `SendMethod` reinvents `PhoenixKit.Integrations` + its encryption
The plan's §5 `SendMethod` ("config (host/port/user/pass/api-key — **encrypted**)") and §9 open question ("Encryption of SMTP creds — need the host's approach (Cloak/vault?)") ignore two facts:

- `PhoenixKit.Integrations` is the existing system for storing external-service credentials (`deps/phoenix_kit/lib/phoenix_kit/integrations/integrations.ex`), with `get_credentials/1`, `save_setup/3`, `connected?/1`, and per-provider definitions.
- `PhoenixKit.Integrations.Encryption` already does **AES-256-GCM** with a key derived from `secret_key_base`, an `enc:v1:` prefix, and idempotent encrypt/decrypt of `api_key`/`secret_key`/`password`-style fields (`deps/phoenix_kit/lib/phoenix_kit/integrations/encryption.ex:1-158`).
- The `Module` behaviour exposes `integration_providers/0` and `required_integrations/0` *specifically so modules can declare providers* (`module.ex:83-85, 113-115`). Providers are "defined in code… External modules can also contribute providers via the `integration_providers/0` callback" (`integrations/providers.ex:9-11`).

The open question in §9 is already answered in the codebase. **Required change:** SMTP/API accounts should be modelled as Integrations rows (newsletters contributes `smtp`, `ses`, `brevo` providers via `integration_providers/0`), and `SendMethod` collapses to a thin newsletters-owned row holding From/signature/priority/limits **plus an `integration_uuid` FK**. This removes the bespoke encryption question, reuses the admin Integrations UI, and is consistent with how the parent Mailer already sources SES creds at runtime (`mailer.ex:202-230`).

### MAJOR — Phase 8 (tracking) likely reinvents `Email.Provider`
`PhoenixKit.Email.Provider` defines `intercept_before_send/2`, `handle_after_send/2`, `track_usage/1`, and `send_test_tracking_email/2` (`deps/phoenix_kit/lib/phoenix_kit/email/provider.ex:11-36`). The current `DeliveryWorker` already routes through `PhoenixKit.Mailer.deliver_email/1` which calls `Provider.current().intercept_before_send` — i.e. tracking interception is already in the send path.

§8's "open pixel + click redirects, bounce/complaint ingestion (webhooks)" needs to state the relationship to this provider layer explicitly. Either (a) reuse `Email.Provider` hooks and stop at ingesting provider webhooks into `Delivery`, or (b) justify a parallel newsletters-owned tracker. The plan currently implies (b) without acknowledging (a) exists.

### MAJOR — Multi-account sending severs the Mailer/Provider seam
`DeliveryWorker.send_email/4` (`workers/delivery_worker.ex:139-150`) calls `PhoenixKit.Mailer.deliver_email/1`. The Mailer resolves a *single* provider via `Provider.current()` and injects runtime config (`mailer.ex:172-230`). §8 of the spec says "build a Swoosh mailer per `SendMethod` at send time." That path **bypasses** `Provider.current().intercept_before_send/handle_after_send` — so any existing tracking/logging silently stops for multi-method sends. The plan must specify that the per-method send path still funnels through the Provider interception (or explicitly accept the loss and migrate tracking to newsletters-owned). This is a correctness *and* reporting-continuity issue, not a style choice.

### MINOR — `required_modules: ["emails"]` deserves re-examination
`newsletters.ex:33` declares the Emails module required. The expansion adds a module-owned `Template` library precisely because Emails templates are optional, and grows tracking + sending in-module. The soft-dependency story (currently `Code.ensure_loaded?` guards in `delivery_worker.ex:117-126` and `newsletters.ex:417-426`) should be revisited: is Emails still *required*, or should it become a truly optional enhancement? Not blocking, but the spec should state the intent.

---

## 2. Domain-model soundness

### MAJOR — Phase 1 does *not* "unlock arbitrary-address mailing" (the worker can't send to contacts)
§7 Phase 1 claims it "*Unblocks arbitrary-address mailing.*" It does not. `Delivery.user_uuid` is `validate_required` (`delivery.ex:52`) and `NOT NULL` in DB (`v79.ex`). `DeliveryWorker.perform/1` calls `get_user(delivery.user_uuid)` (`delivery_worker.ex:42`) and `build_variables/2` reads `user.username || user.email` and signs a **user-bound** unsubscribe token (`delivery_worker.ex:93-109`). `Broadcaster.process_batch/3` hardcodes `user_uuid:` into the insert (`broadcaster.ex:78-91`).

So after Phase 1 you can *store* contacts, but you cannot deliver to them. The "contact_uuid XOR user_uuid" Delivery change, the Broadcaster union resolution, the worker's recipient-agnostic variable/token building, and the nullable-FK migration are all **part of the same unit of work** as Contacts. Either fold the worker + Delivery refactor into Phase 1, or reword Phase 1's shippability claim to "store and manage contact lists" (not "mail to them"). As written, Phase 1's success criterion is false.

### MAJOR — Unsubscribe/suppression is user-only today; contact path is unspecified
`build_variables/2` signs `Phoenix.Token.sign(endpoint, "unsubscribe", %{user_uuid, list_uuid})` (`delivery_worker.ex:94-99`) and the public `UnsubscribeController` consumes it. A `Contact` has neither `user_uuid` nor a `username`. §7 Phase 2 says "Auto-add on unsubscribe/bounce/complaint" — but the unsubscribe *mechanism itself* has no contact-capable token. The plan must specify a contact-scoped token (e.g. `%{contact_uuid, list_uuid}` or a delivery-scoped token) and a controller path that suppresses the contact, not just the user. This couples Phase 2 to the Phase-1 worker refactor and should be called out.

### MAJOR — Per-method limit enforcement vs Oban queue concurrency
§8: "reuse `newsletters_delivery` queue; add scheduling/throttle via queue config + per-method limit checks." This conflates two different rate domains:
- **Oban queue concurrency is global** (one integer for `newsletters_delivery`). It cannot enforce *per-SendMethod* hourly/daily caps.
- Rotation + per-account limits (§5 `SendMethodUsage`, §6.4) require an **atomic claim**: with Oban concurrency of 10+, N jobs simultaneously read-then-increment a usage row → lost updates → limits blown through.

The plan names `SendMethodUsage` but never specifies the concurrency primitive. Required: atomic decrement via `UPDATE … SET used = used + 1 WHERE used < cap RETURNING …` (row-level lock) inside the worker, or a dedicated rate-limiter (Hammer) keyed per method. Without this, Phase 4 is not correct-by-construction.

### MINOR/SIMPLER — `List.kind = user | contact | mixed` is over-modelled
A list naturally holds both `ListMember` (users) and `ContactListMember` (contacts); "mixed" is just "both joins populated." The Broadcaster can `UNION ALL` the two. A `kind` enum adds a migration + changeset validation + a third resolution branch for no functional gain. Drop `mixed` (use `kind` only as a *creation hint* if at all), or drop `kind` entirely and resolve by UNION. Fewer states, no drift between `kind` and actual membership.

### MINOR — `count_active_members`/`subscriber_count` ripple is unspecified
`Newsletters.count_active_members/1` (`newsletters.ex:230-234`) and the denormalized `List.subscriber_count` (updated in `update_subscriber_count/1`, `newsletters.ex:428-434`) count **only** `ListMember`. Once a list can hold contacts, these must become union-aware or every list page and broadcast `total_recipients` is wrong for contact lists. §5/§7 mention "Broadcaster resolves by kind" but never the counter/subscriber-count path. List it explicitly.

### MINOR — `Contact.email` "citext, unique per scope" is AMBIGUOUS
What is "scope"? The migrations are prefix/tenant-aware (`v79.ex` uses `%{prefix}`). Is uniqueness per-tenant, global, or per-list? Also `citext` requires `CREATE EXTENSION IF NOT EXISTS citext` in the migration. Pin this down: recommend `UNIQUE (prefix, lower(email))` semantics via citext + a partial/per-tenant unique index.

### NITPICK — Delivery XOR should be a DB CHECK, not changeset-only
"contact_uuid XOR user_uuid" enforced only in the `Delivery` changeset is weak (raw inserts in `Broadcaster.process_batch` use `repo.insert_all` and **bypass changesets** — `broadcaster.ex:93`). A `CHECK ((user_uuid IS NULL) <> (contact_uuid IS NULL))` constraint in the migration is mandatory or the invariant silently breaks on the batch path.

### NITPICK — Macro substitution has no HTML escaping
`substitute_variables/3` (`delivery_worker.ex:111-115`) does raw `String.replace`. With imported contact names (`{{name}}`), a name containing `<script>` injects markup into the HTML body. Low severity (mail clients largely neutralize it) but worth a note for the Phase-3 macro engine: HTML-escape scalar merge fields.

---

## 3. Phase ordering & dependencies

| # | Defect | Fix |
|---|---|---|
| **P1** | Phase 1 claims it unlocks mailing but the worker can't send to contacts (see §2). | Split: Phase 1a = Contact schemas + import + CRUD; Phase 1b = Delivery XOR + Broadcaster union + worker recipient-agnosticism + contact unsubscribe token. 1b is what actually unlocks sending. |
| **P2** | Suppression (Phase 2) depends on the contact unsubscribe token (Phase 1b) to "auto-add on unsubscribe." | Sequence 1b before/with 2, or move the unsubscribe-token generalization into Phase 2. |
| **P4↔P5** | Multi-account sending (P4) and throttling/limits (P5) are one coupled problem: rotation is *only* correct with working per-method limit enforcement. | Merge P4+P5, or define the atomic-usage-counter contract in P4 and treat P5 as the scheduler/window layer. |
| **P0 missing** | Migration-module decision + Integrations-for-SMTP decision are unstated blockers that affect *every* schema-bearing phase. | Add a Phase 0 (architecture: `migration_module/0`, Integrations-as-SendMethod, tracking-vs-Provider) that must close before P1. |
| **P7** | Spam-check depends on an external service (SpamAssassin host or paid API) whose availability is "decide in Phase 7." | Fine to defer, but mark the whole phase **optional/cut-candidate** so it can't block the critical path. |

Two phases are genuinely, independently shippable as written: **Phase 3 (Templates + macros)** and **Phase 6 (Attachments)** — both are additive and don't touch the send path. Phase 1, 2, 4, 5 are *not* independently shippable for the reasons above.

---

## 4. Gaps / missing considerations

- **Idempotency & retries across methods.** `DeliveryWorker` is `unique: [keys: [:delivery_uuid], states: :incomplete]`, `max_attempts: 3` (`delivery_worker.ex:21-24`). On retry under rotation: does it re-pick a method (possibly hitting a *different* SMTP account and a different `from`)? On failure it already bumps `bounced_count` (`delivery_worker.ex:152-164`), so a transient failure that later succeeds double-counts bounce vs sent. The expansion amplifies this. Spec needs retry-semantics rules: same method on retry? idempotent counter updates?
- **Suppression enforcement at *both* layers is right, but state the race.** Enqueue-time skip + worker guard is correct; call out that a suppression added between enqueue and send is caught only by the worker guard (so the worker guard is the source of truth, not an optimization).
- **Oban queue design.** One global `newsletters_delivery` queue cannot represent N SMTP accounts. Consider Oban's `rate_limit`/`tags` or per-method queues if accounts need isolation — otherwise one throttled account stalls the shared queue. At minimum, state the chosen model.
- **Attachment storage.** §9 leaves "reuse host uploads or module-local?" open. The parent ships a **Storage** module (`deps/phoenix_kit/lib/modules/storage/`). Resolve to reuse it; don't invent module-local file storage.
- **Testing strategy is thin.** "compile + credo + dialyzer + tests" doesn't cover the actually-hard invariants: rotation concurrency (parallel usage-counter claims), suppression enforcement at both layers, contact-import dedup, XOR integrity on the `insert_all` path, backward-compat of existing user-only lists. Name these as required test cases.
- **i18n process.** Locales `en/et/ru` exist (`priv/gettext/*`). Each phase must run `mix gettext.extract` + translate. Fine, but note `et`/`ru` as a maintenance cost that scales with new UI surface.
- **Backward compatibility.** No compat matrix for existing user-based lists after the Broadcaster refactor. The user path must stay observationally identical (same delivery rows, same counters, same unsubscribe). Add an explicit "existing user-list broadcast is unchanged" acceptance test per phase that touches the send path.
- **Security lens ( SMTP creds / imports / From identity ).** (a) SMTP creds must never be plaintext or logged — Integrations.Encryption solves storage; ensure the worker doesn't log decrypted adapter config. (b) XLSX/CSV import of untrusted files — note XLSX zip-quadratic risk and CSV formula-injection on any re-export. (c) `from_email` per SendMethod is admin-only but should at least be syntax-validated; domain-ownership verification is a legitimate future item (note, don't build).

---

## 5. Over-scope / YAGNI (cut or defer)

- **`Campaign` with drip/staged sends (Phase 5).** Drip is a CRM-tier feature; "parity with a desktop bulk mailer" does not require it. **Defer entirely**; keep `Broadcast.scheduled_at` for single-shot scheduling. Reintroduce Campaign only when there's a concrete drip requirement.
- **Spintax in the macro engine (Phase 3).** Niche authoring gimmick; cut from v1, keep the macro engine extensible so it can be added later.
- **Spam-check (Phase 7).** High effort, external dependency, low core value for an internal tool. **Defer to post-v1** or gate behind an explicit "optional" flag.
- **`SendMethod` as a bespoke encrypted-creds table (Phase 4).** Not YAGNI to *send multi-account* — that's the locked requirement — but the *implementation* (custom encryption + custom provider storage) is duplicate work. Use Integrations (see §1). This cuts a whole schema's worth of crypto-handling.
- **A/B testing** — already correctly excluded. Good.
- **Email verification service** — correctly deferred. Good.

Net: cutting Campaign, spintax, and spam-check, and routing SMTP creds through Integrations, removes roughly two phases of effort and de-risks the rest.

---

## (a) Top 5 changes I'd make to the plan

1. **Add a Phase 0 that closes three architectural decisions before any schema work:** (i) implement `migration_module/0` → `PhoenixKit.Newsletters.Migrations` so all new tables ship *in this package*; (ii) model SMTP/API accounts as `PhoenixKit.Integrations` rows contributed via `integration_providers/0`, encrypting with the existing `Integrations.Encryption` (AES-256-GCM) — `SendMethod` becomes a thin From/signature/limits + `integration_uuid` row; (iii) decide tracking reuses `Email.Provider` hooks vs. newsletters-owned, and ensure the per-method send path still funnels through `Provider.intercept_before_send`.

2. **Re-sequence Phase 1 into 1a (Contact + ContactListMember + import + CRUD) and 1b (Delivery `contact_uuid XOR user_uuid` with a DB CHECK, Broadcaster UNION resolution, recipient-agnostic `DeliveryWorker`, and a contact-capable unsubscribe token).** Only 1b actually "unlocks arbitrary-address mailing." Rewrite the Phase 1 shippability claim accordingly, and make `count_active_members`/`subscriber_count` union-aware in the same phase.

3. **Specify the per-SendMethod rate-limit concurrency primitive** (atomic `UPDATE … WHERE used < cap RETURNING` on `SendMethodUsage`, or a Hammer rate-limiter keyed per method). State explicitly that Oban's global queue concurrency cannot enforce per-account caps. Merge the limit work (P4) with the throttle/scheduler work (P5) since rotation is only correct with working limits.

4. **Generalize the suppression/unsubscribe path for contacts** (Phase 2 depends on the Phase-1b token): define a contact-scoped unsubscribe token, make the worker guard (not the enqueue check) the source of truth for suppression, and add retry/idempotency rules for counters (`sent_count`/`bounced_count`) under multi-method retries.

5. **Cut `Campaign`/drip, spintax, and spam-check from v1**; resolve attachment storage to reuse the parent **Storage** module; replace `List.kind = user|contact|mixed` with resolution-by-UNION (drop `mixed`); add a backward-compat acceptance test ("existing user-only lists send identically") to every send-path phase.

---

## (b) Overall verdict

**Sound-with-changes.**

The capability set, hybrid-recipient model, and subsystem decomposition are right, and the locked decisions are defensible. But the plan is **not implementable as written** for three reasons that must be fixed before Phase 1 starts: (1) schema migrations have no declared home and the external-module `migration_module/0` path is the missing prerequisite; (2) `SendMethod` + SMTP-creds encryption reinvents the existing `Integrations` + `Integrations.Encryption`; and (3) Phase 1's central claim ("unlocks arbitrary-address mailing") is false because the `DeliveryWorker` and unsubscribe token are user-only and that refactor isn't in the phase. Fix the Phase-0 decisions, split/resequence Phase 1, merge 4+5, cut the YAGNI phases, and this becomes a clean, shippable roadmap.
