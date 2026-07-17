# Stage 3 — CRM Contact Lists + Account Import — Implementation Plan

**Date:** 2026-07-17 · **Spec:** `../specs/2026-07-15-restructuring-global-spec.md` §4 (+ §4.2 contact-level opt-out, §7 subscribable flag pre-provisioned)
**Process:** subagent-driven (implementer → Sonnet-high reviewer + GLM per task, fix cycles direct); CP3 live test with the user at the end. User priority: **account list import** ("надо импорт аккаунтов доделать").
**Repos:** core `/app` (branch `feature/email-send-profiles-core` — V152 accumulator), `phoenix_kit_crm` (branch off `main`), host wired via path deps, hot-reload on.

## Locked decisions (from the dual-reviewed spec — do not relitigate)

- Import **always creates a NEW contact** (no merge; matching only on the comparison screen).
- Per-list email uniqueness = **DB index on the denormalized member email** (`UNIQUE (list_uuid, email) WHERE email IS NOT NULL`); app pre-check is UX only. Emails may repeat across lists. Contact email stays nullable NON-unique.
- Import row = contact INSERT + membership INSERT in ONE transaction; unique-violation rolls both back → **no orphan contacts** on re-import.
- Unsubscribed member holds the email slot → re-import cannot silently resubscribe.
- Opt-out/consent live on the CONTACT (not membership): `opted_out_at` + `consent` jsonb. Membership `status`: subscribed/pending/removed semantics; the send path (Stage 4) checks member subscribed AND contact not opted out.
- No `is_default` on lists. `subscribable` flag provisioned NOW (used by the Stage-4 preference center).
- NEVER route through `Contacts.connect_user/2` / `find_or_create_user_by_email` (placeholder-user mint).
- Counter cache + PubSub are NET-NEW for CRM (PartyRoles deliberately doesn't broadcast) — borrow the interactions broadcast shape.
- Context modeled on `PhoenixKitCRM.PartyRoles` on **main** (grant/revoke/has_role? style, soft-toggle, actor_uuid audit).
- All DDL = new sections in the **V152 accumulator** (one-open-migration rule). citext on contact email already landed (their V151).

## Tasks

### C1 (core /app): V152 sections — lists, members, contact extensions
New section pair `up_crm_contact_lists`/`down_crm_contact_lists` in `v151.ex`-successor `v152.ex` (follow the section convention already documented in its moduledoc):
1. `phoenix_kit_crm_lists`: uuid PK (uuid_v7), name varchar NOT NULL, slug varchar NOT NULL UNIQUE, description text, status varchar NOT NULL default 'active' (active|archived), `subscribable` boolean NOT NULL default false, subscriber_count integer NOT NULL default 0, metadata jsonb NOT NULL default '{}', timestamps.
2. `phoenix_kit_crm_list_members`: uuid PK, list_uuid uuid NOT NULL FK → crm_lists ON DELETE CASCADE, contact_uuid uuid NOT NULL FK → crm_contacts ON DELETE CASCADE, `email` citext NULL (denormalized snapshot at add-time), status varchar NOT NULL default 'subscribed' (subscribed|pending|removed), subscribed_at timestamptz, unsubscribed_at timestamptz (kept for history even though opt-out is contact-level — records when membership was switched), source varchar NOT NULL default 'manual' (manual|import|form|api), metadata jsonb NOT NULL default '{}', timestamps. Indexes: `UNIQUE (list_uuid, contact_uuid)`; **`UNIQUE (list_uuid, email) WHERE email IS NOT NULL`** (name it `idx_crm_list_members_list_email`); plain index on contact_uuid.
3. `phoenix_kit_crm_contacts` additions: `locale` varchar NULL; `opted_out_at` timestamptz NULL; `consent` jsonb NOT NULL default '{}'.
`down` reverses in order. Bump nothing (@current_version stays 152 — accumulator). Extend V152Test with the new tables/indexes/columns parity checks; fresh-chain V01→V152 run green.

### C2 (CRM repo): schemas + Lists context
`PhoenixKitCRM.Schemas.ContactList`, `PhoenixKitCRM.Schemas.ListMember` (SchemaPrefix, UUIDv7 PKs, changesets; member email NOT cast from forms — set by context from the contact at add-time). Contact schema: add locale/opted_out_at/consent fields (locale validated via core `Languages`-style check if a helper exists; opt-out not form-cast).
Context `PhoenixKitCRM.Lists` (PartyRoles-main style): create_list/update_list/archive_list/list_lists/get_list(!)/by slug; `add_contact_to_list/3` (contact, list, source — writes membership with email snapshot; handles the unique-violation → {:error, :email_already_in_list}); `remove_from_list/2` (status → removed, unsubscribed_at); `subscribed?/2`; `list_members/2` (with filters/pagination like Contacts.list_contacts); counter maintenance in-context + PubSub broadcast (`crm:lists` topic, shape of interactions'); contact-level `opt_out/2` / `opt_in/2` (opted_out_at + consent entry, actor audit like PartyRoles). Tests incl. the race path (unique violation normalized), counter correctness, opted-out semantics.

### C3 (CRM repo): import engine (NO UI yet)
`PhoenixKitCRM.Lists.Import` — pure-ish engine: parse CSV (header-mapped: email required; name/company/locale optional) + TXT/clipboard (one email per line); XLSX behind an optional dep — evaluate `xlsxir`: if it adds heavy NIF baggage, ship CSV/TXT first and report (decision point, not silent skip). Per-row pipeline: normalize (trim/downcase via citext semantics) → in-file dedup prefilter → validate email format → ONE transaction: create contact (source tag in metadata) + insert membership (source: import) → on `idx_crm_list_members_list_email` violation: rollback row, classify (already-in-list / unsubscribed-holder). Returns `%ImportReport{created, added, skipped: %{already_in_list, unsubscribed, no_email, invalid_email, duplicate_in_file}, rows: [...]}` for the UI. Property: re-importing the same file is a no-op (idempotent, zero new contacts). Tests with fixture files incl. shared-mailbox rows, unicode emails, CRLF, BOM.

### C4a (CRM repo): Lists UI — tab, CRUD, members, manual add
Admin tab "Lists" (Tab.new! + routes per CRM conventions): lists index (table_default toggleable + table_row_menu — the A6-established standard; subscriber_count, subscribable toggle, archive), list editor (name/slug/description/subscribable), members page (paginated, status badges, remove action, per-member source/email) + **manual add-by-email form** (email + name + locale; live "already in this list" hint via context check; creates contact + membership per policy). admin_page_header with working back= (fixed in A6) → parentage to Lists index. gettext everywhere; stable form ids.

### C4b (CRM repo): Import UI
Import page per list (reachable from members page): textarea paste + file upload (LiveView uploads) → dry-run PREVIEW (first N rows parsed + full counts) → confirm → run engine → render ImportReport (created/added/each skip bucket, expandable row detail). Must be honest about large files (chunked processing; progress via send/update).

### C4c (CRM repo): comparison ("сличение") screen
Read-only reports page: (1) directory-wide duplicate emails (contacts sharing an email, count + drill-down); (2) cross-list overlap picker (choose 2+ lists → intersection table + counts). No auto-actions.

**CP3 (user live test):** create a list, import a real account CSV, manual add, re-import same file (idempotency visible in report), comparison screen, counters/PubSub, archive.

## Sequencing
C1 → C2 → C3 ∥ C4a → C4b → C4c → CP3. Reviews per task: Sonnet-high + GLM (batch GLM if 529).
