I now have a complete, cross-cutting picture of all 9 CRM commits + the core V152 section. The dialyzer ignore is a well-understood stdlib `MapSet.t()` opaque false positive, narrowly scoped — not hiding a real issue. Rendering the verdict.

---

## Stage 1: Spec Compliance

**Cross-referenced every task (C1–C4c) against the plan and the Locked decisions, verified independently of the implementer's commit messages.**

**Locked invariants — all hold end-to-end:**

- **Always-new-contact import** — `Lists.Import.import_row/4` (import.ex:294–303) builds a fresh `contact_attrs` and calls `Lists.add_new_contact_to_list/3`; never matches an existing contact. Comparison-screen matching is separate (C4c, read-only). ✓
- **Per-list email uniqueness = DB** — `idx_crm_list_members_list_email` partial unique index (v152.ex:224–228); app pre-check in `ListMembersLive.check_email/2` (list_members_live.ex:200–208) is UX-only; the DB constraint is the guard that catches the race (`do_add_member` re-checks on `:email_already_in_list`, list_members_live.ex:222–228). ✓
- **Removed-holds-slot** — confirmed by reasoning + the V152 test "enforces unique (list_uuid, email) only among non-null emails" (v152_test.exs:472–516) + import_test "removed member is not reactivated by an import row sharing its email" (import_test.exs:232). Import always creates a new `contact_uuid`, so it can never trip the reactivate branch; the held slot forces `:email_already_in_list` → classified `:unsubscribed`. ✓
- **Reactivation-only-manual** — the *only* reactivation paths are `resubscribe` / `resubscribe_row` (list_members_live.ex:107–123), both explicit operator button clicks. Import path (`add_new_contact_to_list` → `add_contact_to_list` with a brand-new contact) always takes the `nil → insert_member` branch (lists.ex:157–162), never `reactivate_member`. Cross-feature regression test (202a07b) pins this. ✓
- **Never via `connect_user`/`find_or_create_user_by_email`** — import and manual add both go through `Contacts.create_contact/1` (contacts.ex:128–133), which is a plain changeset insert — no placeholder-user mint. ✓
- **One-txn-per-row / no orphan** — `add_new_contact_to_list/3` (lists.ex:245–254) wraps contact+membership in one transaction; rollback on `:email_already_in_list`/`:already_member`/changeset. import_test "does not create an orphan contact when the membership insert is rolled back" (import_test.exs:263). ✓
- **Counter cache + PubSub net-new** — implemented in-context, broadcast shape mirrors interactions. ✓
- **XLSX documented deferral** — import.ex:46–54, deliberate (xlsxir unmaintained). ✓

**Statuses/sources/error atoms agree across all layers** — DDL CHECK (v152.ex:204–209) ↔ ListMember `@statuses`/`@sources` (list_member.ex:22–23, 63–64) ↔ ImportReport skip_reasons (import_report.ex:11–36) ↔ context return atoms ↔ `apply_result` clauses (import.ex:331–373, exhaustive over both the real-run atoms `:email_already_in_list/:already_member/:changeset` and the preview-only atoms `:unsubscribed/:already_in_list`). ✓

[import.ex:367–373] AMBIGUITY (minor): `apply_result` for `{:error, %Ecto.Changeset{}}` bucket any non-email contact-insert failure as `:invalid_email`. Rows are email-centric and the real errors are `Logger.warning`-logged, so debuggable — but the bucket label can mislead. Acceptable; matches the moduledoc's honesty about preview vs. run.

**Spec Verdict: PASS**

---

## Stage 2: Code Quality

### MINOR — `remove_from_list/2` over-decrements `subscriber_count` for a `pending` member (counter-invariant gap, concern d)
**File**: `lib/phoenix_kit_crm/lists.ex:311–334`
**Problem**: `remove_from_list/1` early-returns only for `status: "removed"`; every other status flips to `removed` and calls `bump_counter(list, -1)`. But `subscriber_count` counts *only* `status == "subscribed"` (see `recount_list/1`, lists.ex:384–393). A `pending` member was never counted, so removing one decrements the cache to −1 / drift. The invariant "subscriber_count integrity across ALL mutation paths" doesn't hold for `pending → removed`.
**Failure scenario**: Stage-4 preference-center double-opt-in creates `pending` members (the status is provisioned in the DDL + schema for exactly this). An operator removing a pending member from the members page silently corrupts the counter. `recount_list/1` repairs it.
**Why latent now**: grep confirms `pending` is unreachable in Stage-3 production code — the only occurrences are a UI comment (list_members_live.ex:453) and a raw `Repo.insert!` test fixture (lists_test.exs:252–260). No active data-corruption path exists today.
**Suggestion**: guard the decrement on the prior status — only bump −1 when `member.status == "subscribed"` (the reactive counterpart `reactivate_member` already does the correct thing for pending→subscribed: +1).
**Rationale**: the counter cache is the live UI's source of truth; the fix is one line and prevents a silent drift the moment Stage 4 lands.

### MINOR — `opt_out/2` / `opt_in/2` mutate the contact without broadcasting (PubSub consistency, concern e)
**File**: `lib/phoenix_kit_crm/lists.ex:466–501` (`set_consent/3`)
**Problem**: Every list/membership mutation in this context broadcasts on `crm:lists` (the moduledoc at lists.ex:8–11 states this is the deliberate divergence from PartyRoles), but `opt_out`/`opt_in` update `opted_out_at` + `consent` with only an activity log, no `broadcast_list_event`. Inconsistent with the context's own stated contract.
**Failure scenario**: latent — these functions aren't wired to any Stage-3 route/handler, and no current LiveView displays opt-out live, so nothing visibly fails. A Stage-4 preference-center UI showing opt-out status live won't refresh without a manual reload.
**Suggestion**: either broadcast a `:contact_opt_out`/`:contact_opt_in` event, or add a one-line moduledoc note that opt-out is intentionally off the `crm:lists` topic (contact-level, not list-level) so the asymmetry is documented rather than accidental.
**Rationale**: the review brief (e) asks specifically for "anything mutating WITHOUT broadcasting"; this is the one case. Low impact because it's unused, but worth a deliberate decision now.

### NITPICK — per-row `get_member_by_email` SELECT on the import error path (deliberate, noted for completeness)
**File**: `lib/phoenix_kit_crm/lists/import.ex:338–346`
**Problem**: The real run calls `Lists.get_member_by_email/2` once per `:email_already_in_list` row to classify removed-vs-active, whereas the dry-run uses the batched `members_by_email/2`. A full re-import of a large file pays N extra SELECTs.
**Rationale this is acceptable (not a defect)**: each failed row already costs a full contact-INSERT-attempt + rollback transaction, which dominates the SELECT; and batching the real run would introduce a TOCTOU window versus the "DB constraint is the single source of truth" design that makes the concurrency story (concern c) clean. The moduledoc at lists.ex:256–264 documents the asymmetry. No change needed.

### Positive observations (deliberately verified)
- **Preview/run can't drift** — both share `process_all`/`process_row` (import.ex:254–290); only the resolver fun differs. This is the single best structural decision in the engine.
- **Defense-in-depth on manual add** — client `email_check` guard *and* DB-constraint fallback that re-checks on race (list_members_live.ex:99–105, 222–228). A crafted `add_member` for a held email can't create an orphan or crash.
- **V152 test** pins FK `ON DELETE CASCADE` rules, both CHECK constraints, and the partial-unique semantics including "different contact, same email → blocked" and "NULL emails unconstrained" (v152_test.exs:441–516).
- **Mass-assignment closed**: `subscriber_count`/`uuid`/`metadata` (ContactList), `opted_out_at`/`consent`/`user_uuid` (Contact), and `email` (ListMember) are all non-castable; `email` is set only by the context from the contact (list_member.ex:6–11, 55).
- **Upload hardening** server-side: `accept: ~w(.csv .txt)`, `max_entries: 1`, `max_file_size: 5_000_000` (list_import_live.ex:37–42); `File.read!` on a server-controlled temp path — no traversal, no type spoofing beyond CSV parsing, 5 MB caps memory.
- **Subscribable checkbox fix verified end-to-end**: original hand-rolled `<input type="checkbox" value="true">` had no hidden `false` fallback → unchecked was omitted from the POST → `cast` never saw the key → flag silently stayed on (a real no-op). Replaced with core `.checkbox`, which renders `<input type="hidden" value="false">` (checkbox.ex:105). Regression test (e3f29fa) honestly exercises the DOM uncheck via `render_change`, not a bare param override.
- **Routes gated like siblings** — lists/import/comparison routes are in the same `build_admin_routes` macro as contacts/companies (routes.ex:65–84), so they inherit the CRM siblings' auth pipeline by construction.
- **Dialyzer ignore** addition is a narrowly-scoped stdlib `MapSet.t()` opaque false positive with a clear justification — not burying a real type error.

**Quality Summary:** 0 critical, 0 major, 2 minor, 1 nitpick
**Quality Verdict:** Ship (fix the two latent minors while the context is fresh)

---

## Overall Verdict: PASS

The Stage 3 build is spec-complete, the locked invariants hold under adversarial cross-cutting scrutiny (concurrency, reactivation-only-manual, removed-holds-slot, no-orphan all verified by reasoning + tests), and the code quality is genuinely high — the shared preview/run pipeline, the honest moduledocs, and the defense-in-depth on the manual-add race are exactly what per-task reviews can't see but a cross-cutting pass should confirm.

**If you want a fix cycle** (optional, neither blocks merge — both are Stage-4-reachable, not Stage-3-active):
1. `lib/phoenix_kit_crm/lists.ex:313–316` — guard the `bump_counter(list, -1)` on `member.status == "subscribed"` so removing a (future) `pending` member doesn't drift the counter.
2. `lib/phoenix_kit_crm/lists.ex:466–501` — either broadcast on opt-out/opt-in, or add a one-line moduledoc documenting the intentional asymmetry vs. the list/membership mutations.

Both are one-line changes; I can SendMessage the implementer directly with these if you'd like.
