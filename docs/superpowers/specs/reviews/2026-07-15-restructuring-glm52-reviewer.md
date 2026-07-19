I now have all evidence verified across five codebases plus the live DB. Here is the complete review.

---

# Plan Review — Ecosystem Restructuring Global Spec (v1)

**Spec:** `docs/superpowers/specs/2026-07-15-restructuring-global-spec.md`
**Reviewed against:** core `/app`, emails `/root/projects/phoenix_kit_emails`, CRM `/root/projects/phoenix_kit_crm` (+ `.claude/worktrees/crm-party-roles`), newsletters (this repo, `feature/newsletters-sending-foundation`), host `/root/projects/hydroforce`, and the **live hydroforce DB** (`phoenixkit_hello_world_dev`, version stamp **150**). Every load-bearing claim below is grounded in code or live DB state, independently verified — four parallel research sweeps cross-checked against direct `psql`/file reads.

## Cross-cutting finding (read first): the spec is one release-step stale on versions, and §5 is half-built

The single most pervasive problem is **version staleness**, all pointing the same way (the code advanced one core version — V150→V151 — after the spec was frozen):

- **`@current_version` is 151, not 150.** `postgres.ex:1322` → `@current_version 151`. The spec says "150" in §5 ("lands at V151+") and §8a ("core fork at V150").
- **V151 already exists and already implements the §5 Send-Profiles→core move.** `v151.ex` is literally titled *"Newsletters/CRM/Core restructuring — accumulator migration"* and its first section (`up_send_profiles_to_core_email`) creates `phoenix_kit_email_send_profiles` (l. ~63), copies rows `INSERT … SELECT … ON CONFLICT (uuid) DO NOTHING` (l. ~88), then `DROP TABLE … phoenix_kit_newsletters_send_profiles CASCADE` (l. ~98) — exactly the "pure copy preserving UUIDs" §5 describes, including the deliberate non-touching of `broadcasts.send_profile_uuid`. So §5's headline migration is **not future work — it is committed code** (though **not yet applied** to the dev DB: the live DB still has `phoenix_kit_newsletters_send_profiles` and no `phoenix_kit_email_send_profiles`).
- **The host DB is at V150, not V143.** Live `obj_description('public.phoenix_kit')` → `150`. So §8a's "host DB is at V143 → run `phoenix_kit_update_v143_to_v150`" is doubly stale: the DB is already at 150; the real outstanding run is **V150→V151**.
- **Most §3 Stage-0 prerequisites are already satisfied.** `crm-party-roles` is merged to `main` (the worktree is *behind* main — main added `actor_uuid` audit logging + tests; `phoenix_kit_crm_party_roles` table is live via core V148); CRM is already a `path:` dep in hydroforce `mix.exs:106`; `crm_enabled=true` in the live settings; `reloadable_apps` in `config/dev.exs:65` **already** lists `:phoenix_kit, :phoenix_kit_emails, :phoenix_kit_newsletters, :phoenix_kit_crm`. §8a presents nearly all of its tasks as pending when they are done.

This staleness does **not** make the architecture wrong — the design in v151 matches the spec's intent precisely. But a fresh implementer reading this spec would (a) try to create V151 (it exists), (b) state current_version as 150, (c) run the wrong update range, and (d) redo Stage 0. **The spec needs a version pass before anyone implements against it.** Worse, because v151 is an *accumulator* whose moduledoc declares the project's **"one open migration" rule** ("while V151 is unreleased, every DDL step of the restructuring plan lands here as its own section rather than opening a new vNNN"), §4/§6/§7 — which each say "(core migration, next free version)" / "new core migration" — **contradict the repo's own convention**: those tables/columns must be appended as sections *inside v151.ex*, not new v152/v153 files. The spec never acknowledges the accumulator or the one-open-migration rule.

---

## §1 — Direction (user decisions)

| Decision | Sound? | Evidence |
|---|---|---|
| Remove newsletters lists; recipient source = CRM list XOR user-group(=roles) | ✅ | Clean XOR; one source per broadcast (§7) avoids mixed-list resolution entirely. Roles-as-groups needs no new entity. |
| Send settings → core; base send works without emails/Amazon | ✅ | Provider seam exists (`email/provider.ex:11-32`); Integrations validators already call SES `GetSendQuota` and Brevo `GET /account`. |
| Settings→Emails = one expandable core tab | ✅ (with seam caveat, §5) | No section-component callback exists yet (`module.ex:137-148`); new seam is justified. |
| Templates → core | ✅ | Table already core-owned (V15/V80); schema/context live in emails → move is real. |
| Brevo analytics via polling | ✅ | Unsigned-webhook rationale is correct; Oban pattern exists. |

**§1 Verdict: Sound.**

---

## §2 — Relationship to v3 spec

Mostly accurate mapping. **One factual error:**

- 🔶 **"Idempotency unique indexes `(broadcast_uuid, user_uuid)` / `(broadcast_uuid, contact_uuid)` — CARRIED OVER" implies these exist. They do not.** Live `pg_indexes` on `phoenix_kit_newsletters_deliveries` shows only `idx_newsletters_deliveries_broadcast` (non-unique), `idx_newsletters_deliveries_user` (non-unique), and a partial unique on `message_id`. No `(broadcast_uuid, user_uuid)` unique index exists in any migration (grep across `/app/lib/phoenix_kit/migrations` = empty). **Actual idempotency today is Oban-level:** `delivery_worker.ex:24` → `unique: [period: :infinity, keys: [:delivery_uuid], states: :incomplete]` — keyed on `delivery_uuid`, not the broadcast/recipient pair. So when §7 reasons "the per-recipient idempotency indexes cannot stop the same ADDRESS twice," it is reasoning about indexes that don't exist yet. The per-recipient indexes are **new**, not carried over; the address-level unique is the **first** DB-level dedup, not an addition on top of existing per-recipient indexes. (The argument's *conclusion* — that an address-level index is needed for shared-mailbox dedup — is still correct; the framing is what's off.)

**§2 Verdict: Sound-with-changes** (correct the idempotency-index provenance).

---

## §3 — Stage plan

Staging and parallelism are coherent ((1+2) ∥ 3; 4 needs 1+3; 5,6 independent). The problem is staleness: **Stage 0 prerequisites are already met** (see cross-cutting finding). Net effect: the plan can start at Stage 1/3 immediately; the "prerequisites" list reads as future work.

**§3 Verdict: Sound-with-changes** (mark Stage 0 as ✅ done; re-baseline versions).

---

## §4 — CRM contact lists (Stage 3)

**§4.1 domain model — sound.** The denormalized member-email snapshot + dual unique indexes is the right call and the spec's race-condition reasoning is correct: under the always-create-new-contact import policy, two parallel imports of the same address get different `contact_uuid`s, so a `UNIQUE(list_uuid, contact_uuid)` index never fires; the `UNIQUE(list_uuid, email) WHERE email IS NOT NULL` on the **snapshot** is what actually guarantees per-list email uniqueness. This is a genuinely good design that a naïve app-level check would get wrong.

**Grounded confirmations:**
- `crm_contacts.email` is today `VARCHAR(255)`, nullable, **no index at all** (`v138.ex:51`; live `varchar|YES`; only `idx_crm_contacts_user_uuid` exists) → §4.2's citext+plain-index change is real and necessary. ✅
- The `connect_user` guard (§4.5) is **real and well-caught**: `contacts.ex:235-236` `connect_user/2` calls `find_or_create_user_by_email/1`, which at `contacts.ex:281-291` `register_placeholder/1` does `:crypto.strong_rand_bytes(24)` → registers a placeholder core user tagged `custom_fields.source="crm_contact"`. Routing list migration through it would silently mint placeholder users. The spec's "link only to existing users; never register" guard is correct.

**Issues:**

- 🟠 **MAJOR — "existing CRM PubSub" for `subscriber_count` does not exist; the counter cache is net-new.** §4.1 says counter maintenance "broadcast[s] over the existing CRM PubSub for live UI." But `PartyRoles` **explicitly does not broadcast** (`party_roles.ex:9-11`: *"There is no live-updating tab for roles yet, so unlike interactions this context does not broadcast over PubSub"*). The only CRM PubSub is interactions-specific (`pub_sub.ex:44` `broadcast_interaction/2` on `crm:contact:<uuid>:interactions`). `count_contacts`/`count_companies` are **live aggregates**, not maintained counters — grep for `count_cache|cached_count|subscriber_count` across both CRM lib trees is empty. So the cached-counter + PubSub pattern the lists subsystem wants has **no precedent in CRM**; it must be built fresh (or the interactions broadcast pattern borrowed). The spec overstates existing infrastructure.

- 🟡 **MINOR — SchemaPrefix is misattributed.** §3/Stage 0: "CRM `feature/crm-party-roles` merged (ships SchemaPrefix…)". `SchemaPrefix` ships from **core** (`/app/lib/phoenix_kit/schema_prefix.ex`); CRM schemas merely `use PhoenixKit.SchemaPrefix` (`contact.ex:13`). Credit for "shipping" it belongs to core; the CRM branch *uses* it.

- 🟡 **MINOR — PartyRoles naming is approximate, and the worktree is the wrong reference.** §4.1 says the context is "modelled on `PhoenixKitCRM.PartyRoles` (subscribe/unsubscribe/subscribed?/list_members)". The actual API is `grant_role/revoke_role/has_role?/list_roles/list_contacts_with_role` (main `party_roles.ex:35/75/107/122/153`) — soft-toggle (`is_active=false`, never hard-delete) + a single `actor_uuid` audit point. More importantly, **`main` is ahead of the worktree** (main added `actor_uuid` audit logging; the worktree lacks it). Any "mirror the pattern" work must reference **main**, not `.claude/worktrees/crm-party-roles`. The soft-toggle membership model is actually a good fit for the lists `status` field, but the spec should name the real functions.

- 🟡 **MINOR — `party_snapshot` is a JSONB multi-field blob, not a scalar.** §7 leans on "the CRM `party_snapshot` pattern" for `Delivery.recipient_email` (a single citext column). `party_snapshot` (`v138.ex:153`) is `JSONB` holding `{source,name,company,role_in_company,department}`. The closer single-column scalar precedent is `supplier_name_snapshot VARCHAR(255)` (`v149.ex:43`) or the cart price snapshots. The denormalization *idea* transfers; the *shape* does not — model `recipient_email` on the scalar precedent.

**§4 Verdict: Sound-with-changes.** The core domain model (denormalized snapshot + dual indexes, one-txn-per-row import, connect_user guard) is sound and the spec's own §9 already fixed the raciest holes. Fix the PubSub/counter precedent, the SchemaPrefix attribution, and reference main's PartyRoles API.

---

## §5 — Core "Settings → Emails" + Send Profiles (Stage 1)

**Grounded confirmations:**
- The double-tab hazard is **real**: `emails.ex:917-933` registers a routable tab `Tab.new!(id: :admin_settings_emails, …, permission: "emails", live_view: {…Web.Settings, :index})`, collected by `ModuleRegistry.all_settings_tabs/0` (`module_registry.ex:128-134`). If core adds its own Emails tab and emails keeps this one → two tabs. ✅ The spec correctly flags this.
- `from_name`/`from_email` are **read-with-fallback, not seeded**: `mailer.ex:471-485`/`:489-503` read `Settings.get_setting` → fall back to `Config.get` → hardcoded default; they are **not** in `Settings.get_defaults/0` (only compile-time `config.ex:140-141`). ✅ §9's corrected wording is accurate.
- `v145.ex:35-38` `integration_uuid UUID NOT NULL` ✅; `broadcasts.send_profile_uuid` is a bare UUID with no FK ✅ (schema `define_field: false`, migration `v145.ex:58` no `REFERENCES`) → zero re-pointing needed, confirmed by v151 leaving it untouched.
- `record_validation/2` → `validation_status` → live UI (`integrations.ex:1010-1045`, broadcasts `Events.broadcast_validated`) ✅ — Stage 2's "return `{:ok, note}`" mechanism already exists.
- **No section-component callback exists today** (`module.ex:137-148` — `settings_tabs/0` returns `[Tab.t()]`, page-shaped; grep for `email_settings_sections`/`settings_sections` = empty). So the new seam is genuinely new, and **it is consistent with existing discovery**: `ModuleRegistry` would extend naturally (`all_email_settings_sections/0` = `flat_map(safe_call(&1, :email_settings_sections, []))`). The Provider analogy is apt. ✅

**Issues:**

- 🔴 **CRITICAL (staleness) — §5's headline migration already exists as v151.** "core `@current_version` is **150**, so this lands at **V151+**" is wrong on two counts: current_version is **151**, and **V151 already implements the move** (create core table, copy-by-uuid, drop newsletters table). Per the one-open-migration rule (v151 moduledoc), all further restructuring DDL also lands *inside* v151, not "V151+". The spec must be rewritten to: "current_version 151; send-profiles move is the first section of the open V151 accumulator; remaining stages append sections to V151."

- 🟠 **MAJOR — the spec omits the newsletters-side code removal that v151's table drop forces.** v151 drops `phoenix_kit_newsletters_send_profiles`, but the newsletters library still ships the code that reads it: schema `send_profile.ex:25` (`schema "phoenix_kit_newsletters_send_profiles"`), context `list_send_profiles`/`get_send_profile!`/`change_send_profile` (`newsletters.ex:427-440+`), three admin tabs (`:admin_newsletters_send_settings` + `_new` + `_edit` → `Web.SendProfiles`/`Web.SendProfileEditor`, `newsletters.ex:175-206`), and the LiveViews themselves. The moment v151 applies, all of this queries a non-existent table. The spec says only "`PhoenixKit.Newsletters.ProviderOptions` moves to core" — it must also enumerate **deleting the newsletters SendProfile schema/context/LiveView/admin-tabs in lockstep** with the migration, or the newsletters module is broken between the core PR and the newsletters PR. (This is the same three-PR release-coupling the Phase-1 review flagged.)

- 🟠 **MAJOR — the section-component rendering model is under-specified.** The emails "tracking/SQS/retention" the spec wants to inject as sections are **not** portable components today: they are stateful cards in one LiveView (`web/settings.ex` handlers `update_email_retention`, `toggle_sqs_polling`, `update_visibility_timeout`, … bound to HEEX in `settings.html.heex`). A callback "returning section components" is consistent with *discovery*, but the spec doesn't say how a core-owned page renders and routes events for stateful module-contributed cards. Options (stateless function components vs `live_component` with their own events vs core delegates phx-events back) have very different costs. The crux of the §5 seam is left to imagination.

- 🟡 **MINOR — `default_email_integration_uuid` routing does not exist.** The spec writes "`deliver_email/2` routes through it when set" as if it's a tweak. `deliver_email/2` (`mailer.ex:196-226`) has **no** integration-uuid branch (grep: zero matches for the setting). Building that routing — choosing the integration, building per-call Swoosh config, threading it past the SES-only `deliver_with_runtime_config` enrichment (`mailer.ex:241-249`) — is new work. (Note `deliver_via_integration/3` at `:294` already does the per-call-config seam correctly and is the right primitive to call.)

**§5 Verdict: Sound-with-changes.** Design (double-tab removal, bare-UUID no-repoint, fallback-not-seeded, validator-note mechanism) is correct and well-grounded. But the version/accumulator staleness is critical, and two real scoping gaps (newsletters code removal; section rendering model) must be pinned down before implementation.

---

## §6 — Templates in core (Stage 6)

**Grounded confirmations:**
- Table `phoenix_kit_email_templates` is core-owned (`v15.ex:32` creates it; `v80.ex:30-35` ALTERs subject/html_body/text_body to JSONB via `jsonb_build_object('en', …)`). ✅ The schema *module* lives in emails (`template.ex:116-136`) — so "move schema/context/UI from emails→core" is real; the table is already core. Spec's wording is accurate.
- Per-locale JSON-map columns confirmed (`template.ex:121-123` `:map`); row-per-language does **not** exist. ✅ T2 premise correct.
- Locale plumbing is real: `Auth.update_user_locale_preference/2` (`auth.ex:1566`) writes `custom_fields["preferred_locale"]`; `DialectMapper.extract_base/1` (`dialect_mapper.ex:212`, `extract_base(nil)→"en"`) exists; `get_translation/3` (`template.ex:180-194`) does exact→base→default→any-first→`""`. ✅

**Issues:**

- 🟡 **MINOR (factual) — there are FOUR hardcoded `"en"` sites, not three; §9's "third site" is still an undercount.** Verified: `delivery_worker.ex:177`, `broadcast_editor.ex:283` (spec said 282 — off-by-one; 282 is the `defp` line) and `:293`, **plus `broadcast_details.ex:186`** which the spec misses entirely. The three-repo lockstep release must touch all four newsletters call-sites, not three.

- 🟡 **MINOR (factual) — the locale hook is not on "all" core on_mount variants.** §6: "hooks attached in all core on_mount variants." `attach_locale_hook/1` (`phoenix_kit_web/users/auth.ex:689-702`, handler `:phoenix_kit_locale_handler` → event `"phoenix_kit_set_locale"`) is attached **only** by the scope-bearing variants `:phoenix_kit_mount_current_scope` (`:465`), `:phoenix_kit_ensure_authenticated_scope` (`:499`), `:phoenix_kit_redirect_if_authenticated_scope` (`:543` else-branch). The non-scope `:phoenix_kit_mount_current_user` (`:459`) and `:phoenix_kit_ensure_authenticated` (`:469`) do **not** attach it. If the newsletters preference-center or recipient-side view mounts on a non-scope variant, `preferred_locale` won't persist. Pick the right on_mount.

- 🟡 **MINOR — two base-language extractors will coexist.** `get_translation` already derives the base locale inline (`template.ex:185` `locale |> String.split("-") |> List.first()`); the spec proposes `DialectMapper.extract_base/1` for the recipient side. They agree today, but the spec should pick one (DialectMapper) and route both through it to avoid drift.

- 🟡 **MINOR — the resolution chain references a "template default language" that has no storage.** §6: "recipient locale → **template default language** → en." Today `default_locale` is only a function-arg default hardcoded to `"en"` (`template.ex:180`); there is **no per-template `default_language` column** (grep empty). Row-per-language must add one (e.g. `default_language VARCHAR` on `phoenix_kit_email_templates`) or the "template default language" step of the spec's own chain has no source. The migration isn't fully mechanical.

- 🟢 **NITPICK — `validate_locale_value` is an explicit-path validator, not a "registered field definition."** §6 calls `preferred_locale` an "auto-registered field definition." It's actually a free-form `custom_fields :map` (`user.ex:75`) whose `preferred_locale` key is validated only when written through `update_user_locale_preference/2` → `validate_locale_value` (`user.ex:373-389`). Fine for the spec's purposes (newsletters will use the Auth path), but don't assume a changeset-level per-key validator.

- ✅ **Composition (T3) and packs (T4) are honestly scoped** — "does NOT exist today" (current "composition" is wrapper + `{{content}}` + send-profile signature), and T4's seed-if-missing-by-slug + "disable does not delete (delivery history)" + `metadata.source_module` are all sound and consistent with the codebase's `metadata JSONB` + soft-reference patterns.

**§6 Verdict: Sound-with-changes.** Multilingual T2 is the right call and rides on real, verified infrastructure. Corrections are factual (4 sites, hook scope, default-language column) — none structural.

---

## §7 — Newsletters on new recipient sources (Stage 4)

**Grounded confirmations:**
- `Delivery.user_uuid` is **NOT NULL** today (`v79.ex:138`; live `is_nullable=NO`) → "→ nullable" is a real change. `crm_contact_uuid` and `recipient_email` are **absent** (grep empty; live columns confirm). `source_type/source_uuid/source_params` and `newsletters_user_optouts` are **absent** (spec-only). ✅ §7 is genuinely future work.
- The XOR + snapshot + person-scoped-token design is sound. Opt-out living on the contact (one home for both source kinds) is the legally safer and architecturally cleaner choice.

**Issues:**

- 🟠 **MAJOR — the `(broadcast_uuid, user_uuid)` idempotency indexes the spec builds on do not exist.** (See §2.) §7's `UNIQUE(broadcast_uuid, recipient_email)` is the right *addition*, but the spec must reframe it as "the **first** DB-level per-broadcast dedup" alongside **new** `(broadcast_uuid, user_uuid)`/`(broadcast_uuid, crm_contact_uuid)` partial uniques — not "carried over." The implementer also needs to reconcile this with the existing **Oban** uniqueness (`delivery_worker.ex:24`, keyed on `delivery_uuid`): the DB unique + Oban unique will coexist, and `insert_all … ON CONFLICT DO NOTHING` (required, since insert_all bypasses changesets) must be the write path for the address-level guarantee to actually fire.

- 🟡 **MINOR — §4.5 omits the broadcast re-pointing that unblocks dropping `list_uuid`.** `broadcasts.list_uuid` is **NOT NULL with an `ON DELETE RESTRICT` FK** to `phoenix_kit_newsletters_lists` (`v79.ex:87,103-106`; live `is_nullable=NO`). You cannot drop `list_uuid` until every broadcast is re-pointed to `source_type='crm_list', source_uuid=<new crm_list uuid>`. §4.5 migrates lists and members but says nothing about broadcasts; §7 says `list_uuid` is "removed (after data migration §4.5)" without making the broadcast re-point an explicit step. It must be part of the same data-migration window.

- 🟡 **MINOR — the unsubscribe token currently embeds `list_uuid`; removing it is a code breakage the spec doesn't flag.** `delivery_worker.ex:137` builds `token_data = %{user_uuid: user.uuid, list_uuid: broadcast.list_uuid}` and signs the token from it. §7's "person-scoped token" requires rewriting this; the spec states the *goal* but not that the existing token path depends on the very `list_uuid` being removed.

- 🟢 **NITPICK — make `UNIQUE(broadcast_uuid, recipient_email)` partial for consistency.** §4.1 carefully uses `WHERE email IS NOT NULL`; §7 doesn't repeat the qualifier. Postgres allows multiple NULLs in a unique index so there's no false collision, but for parity with §4.1 (and because no-email contacts are "skipped, never an error"), state `WHERE recipient_email IS NOT NULL` and make `recipient_email` write-time-populated.

**§7 Verdict: Sound-with-changes.** The XOR/snapshot/address-dedup model is sound and the contact-level opt-out is the right call. Fix the idempotency framing, add the broadcast re-pointing step to §4.5, and flag the token/list_uuid breakage.

---

## §8a — Dev environment

**Largely already done / stale** (see cross-cutting finding):
- "Wire the CRM fork" → already `mix.exs:106` path dep. "pulls `phoenix_kit_comments` transitively" → ✅ (`phoenix_kit_crm/mix.exs:80`). "restart so the module registers" → `crm_enabled=true` already.
- "extend `reloadable_apps`" → already extended (`config/dev.exs:65` lists all four).
- "host DB is at V143 → run `v143_to_v150`" → **DB is at V150; run `v150_to_v151`** (which applies the §5 send-profiles move).

**§8a Verdict: Sound-with-changes** (rewrite to match reality: V150→V151 is the only outstanding run; mark wiring/reload tasks done).

---

## What the plan gets factually wrong (consolidated)

1. `@current_version` is **151**, not 150; **V151 already implements §5's send-profiles move** (§5, §8a).
2. Host DB is at **V150**, not V143 (§8a).
3. There is **no** `(broadcast_uuid, user_uuid)` unique index today — idempotency is Oban-on-`delivery_uuid` (§2, §7).
4. **Four** hardcoded `"en"` sites, not three; line is 283 not 282; `broadcast_details.ex:186` missed (§6).
5. Locale hook is on **scope-bearing** on_mount variants only, not "all" (§6).
6. **SchemaPrefix** is a core module, not shipped by the CRM branch (§3).
7. **No cached-counter + PubSub** precedent exists in CRM — `subscriber_count` caching is net-new (§4).
8. **`party_snapshot` is JSONB multi-field**, not a scalar; model `recipient_email` on `supplier_name_snapshot` (§4/§7).
9. CRM `party_roles` worktree is **behind main** (main has audit logging) — reference main (§4).

## What the plan misses

1. **Newsletters-side SendProfile code removal** (schema/context/3 admin tabs/LiveViews still target the table v151 drops) — §5.
2. **Broadcast `list_uuid` → `source_type/source_uuid` re-pointing** as an explicit §4.5 step (NOT NULL + RESTRICT FK blocks the drop) — §4.5/§7.
3. **The v151 accumulator / one-open-migration rule** — §4/§6/§7 say "new core migration / next free version" but must append sections to V151 — §3/§5.
4. **Section-component rendering model** for stateful emails cards inside the core page — §5.
5. **`default_language` column** on templates (the resolution chain's "template default language" has no storage today) — §6.
6. **Token code embeds `list_uuid`** — person-scoped token rewrite is forced, not just designed — §7.
7. **`default_email_integration_uuid` routing is new build**, not a tweak — §5.

## Verdicts per section

| Section | Verdict |
|---|---|
| §1 Direction | **Sound** |
| §2 v3 mapping | **Sound-with-changes** (idempotency-index provenance) |
| §3 Stage plan | **Sound-with-changes** (Stage 0 already done; versions) |
| §4 CRM lists | **Sound-with-changes** (PubSub/counter precedent; PartyRoles ref→main; SchemaPrefix attribution) |
| §5 Settings→Emails + Send Profiles | **Sound-with-changes** (CRITICAL staleness; newsletters code-removal gap; rendering model) |
| §6 Templates | **Sound-with-changes** (4 sites; hook scope; default_language column) |
| §7 Newsletters sources | **Sound-with-changes** (idempotency framing; broadcast re-point; token breakage) |
| §8a Dev environment | **Sound-with-changes** (mostly already done; V150→V151) |
| §9 Review log | n/a (accurate record) |

---

## Overall Verdict: **Sound-with-changes**

This is a strong, unusually self-critical spec — the §9 review log already pre-fixed the raciest domain holes (denormalized member-email index, one-txn-per-row import, double-tab hazard, plaintext-secret carryover awareness), and the core architectural decisions (recipient-source XOR, send-settings-to-core, templates-to-core, contact-level opt-out, address-level send dedup) are sound and fit PhoenixKit conventions (Module behaviour callbacks, Provider seam, core-versioned migrations, Integrations-as-keys, loose-UUID cross-module refs). It is **not** Needs-rework: no architectural rethink is required.

But it ships with **one critical staleness vein** (everything version-numbered is one release behind reality — current_version 150→151, V151 already implements §5, host DB V143→V150, Stage 0 prerequisites already satisfied, `reloadable_apps` already extended) and **a cluster of factual errors and omitted steps** that would each trip an implementer: the non-existent `(broadcast_uuid, user_uuid)` indexes, four-not-three `"en"` sites, the newsletters SendProfile code v151 orphans, the broadcast `list_uuid` re-point the RESTRICT FK demands, the v151 accumulator convention the "new migration" language contradicts, and the under-specified section-component rendering model.

**Recommended pre-implementation pass (ordered):**
1. **Version reconciliation** — restate current_version=151; declare V151 the accumulator target for *all* §4/§6/§7 DDL (one-open-migration rule); mark Stage 0 + §8a wiring/reload tasks done; set the only outstanding dev run to V150→V151.
2. **Add the §5 newsletters-side removal scope** (SendProfile schema/context/3 tabs/LiveViews) and the §5 section-component rendering model (live_component vs stateless + event routing).
3. **Add the §4.5 broadcast `list_uuid`→`source_type/source_uuid` re-point step** and reframe §7's idempotency indexes as new (with the Oban/insert_all reconciliation), partial `WHERE recipient_email IS NOT NULL`.
4. **Correct the §6 count** (4 `"en"` sites), note the hook-scope and `default_language`-column gaps, and route base-locale extraction through `DialectMapper` once.
5. **Reference CRM `main`** (not the worktree) for the PartyRoles pattern; re-attribute SchemaPrefix to core; acknowledge `subscriber_count` caching + PubSub as net-new.

With those, this is ready to implement stage-by-stage as designed.
