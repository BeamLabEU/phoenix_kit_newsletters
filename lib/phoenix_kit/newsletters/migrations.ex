defmodule PhoenixKitNewsletters.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_newsletters` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`. This follows the canonical shape
  documented in `phoenix_kit_hello_world`'s README ("Versioned migrations",
  "Adopting a table core already creates") and its
  `mix phoenix_kit_hello_world.audit_migrations` task: **two readers**
  (`migrated_version/1` for migration context, `migrated_version_runtime/1`
  for Mix-task context), `up/1` re-reading the version before it changes
  anything, and a namespaced `COMMENT ON TABLE` marker on one anchor table.
  `PhoenixKitCustomerSupport.Migrations` and `PhoenixKitManufacturing.Migrations`
  are the closest sibling examples of this exact adoption situation.

  ## Ownership situation — read before touching

  Both `phoenix_kit_newsletters_broadcasts` and
  `phoenix_kit_newsletters_deliveries` are core's baseline. Core's
  `ExpectedSchema` manifest records both tables' `since: 79` — a REAL
  pre-squash migration version (the manifest's generator order is
  `(since, class, id)`, and other entries in this same file document the
  highest `since` value present as an actual migration number), not an
  internal manifest counter unrelated to core's migration history. So both
  tables actually originated in core's migration `V79`, well before the
  `V135` squash — `V135`'s own literal `CREATE TABLE` text is what a fresh
  install runs today, but that text is core's squash-time snapshot of `V79`'s
  shape, not the tables' original creation point. `V145`, `V152`, `V155`,
  `V156` and `V158` each layered a further shape change on top afterward
  (send profiles, CRM-sourced recipients, the recipient CHECK, dropping
  `list_uuid`, attachments). On every existing install both tables already
  have their full current shape before this chain ever executes — this is
  an ADOPTION, not a create. Varchar widths are never restated as a second
  number: `PhoenixKit.Newsletters.Broadcast.column_widths/0` and
  `PhoenixKit.Newsletters.Delivery.column_widths/0` are the single shape
  authority this chain's DDL interpolates.

  Unlike `PhoenixKitCustomerSupport.Migrations` (whose `changed_by_uuid`
  column has one documented core-manifest/literal-text discrepancy it must
  correct) and `PhoenixKitManufacturing.Migrations` (whose 3 tables have a
  genuine pre-absorption module-owned history, requiring an `ALTER TABLE
  ... ADD COLUMN IF NOT EXISTS` safety net for hosts still on that old
  shape), this module never shipped its own migration file before this one
  (`git log --all -- '*migration*'` in this repo confirms it) — so there is
  no risk of THIS package's own pre-adoption history disagreeing with core's.
  The `V79`-into-`V135` squash IS exactly the kind of event that produced a
  real, documented discrepancy for customer_support's `changed_by_uuid`
  column, so it is not dismissed here as a non-issue by construction — it
  was checked. A dedicated research pass (core's migration source across
  `V135`/`V145`/`V152`/`V155`/`V156`/`V158`, core's structured
  `ExpectedSchema.objects/1` `revisions` field, and a live, fully-migrated
  Postgres catalog query) confirmed, at high confidence, that the squashed
  `V135` text, the manifest's structured revisions, and the live catalog all
  agree on both tables' shape column-for-column, with **zero discrepancies**.
  So V1 here is a verified no-op-shape adoption: `CREATE TABLE IF NOT
  EXISTS` (full final shape) + a semantically-guarded PK, CHECK(s), indexes
  and FKs (existence checked
  by shape against `pg_constraint`/`pg_index`, not by object name — see
  "Guards are semantic, not name-based" below) + the version-marker
  `COMMENT` — **no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` or `ALTER
  COLUMN ... DROP NOT NULL` safety-net section anywhere in this file.**

  The chain anchors its version marker on `phoenix_kit_newsletters_broadcasts`
  — this module's own hub table (same reasoning
  `PhoenixKitCustomerSupport.Migrations` used to pick `phoenix_kit_tickets`
  over a leaf table, and `PhoenixKitManufacturing.Migrations` used to pick
  `phoenix_kit_machines`): `phoenix_kit_newsletters_deliveries` carries a
  real FK back to it (`ON DELETE CASCADE`), so broadcasts is the one table
  at risk of being dropped independently that every other adoption in this
  chain ultimately depends on — not deliveries, which nothing else
  references.

  ### The `list_uuid` removal — read before "restoring" it

  `phoenix_kit_newsletters_broadcasts` originally had a `list_uuid` column
  (core `V135`), with its own FK (`fk_newsletters_broadcasts_list`) and
  index (`idx_newsletters_broadcasts_list`) — the old `List`/`ListMember`
  mailing-list model. Core's `V156` dropped all three (column, FK, index)
  outright once this module moved audiences onto CRM contact lists /
  core roles instead (`source_type` "crm_list" / "user_group" — see
  `PhoenixKit.Newsletters.Broadcast`). This chain's V1 reproduces the
  table's shape **after** that drop: `list_uuid`, its FK and its index
  never appear anywhere in `up_statements/2`. Do not add them back — a
  test in `migrations_test.exs` asserts their absence directly. Postgres
  does not reuse a dropped column's ordinal position, so
  `phoenix_kit_newsletters_broadcasts`' live column positions actually skip
  from `template_uuid` (6) straight to `status` (8) — `attachments` (V158)
  lands at position 23, after `source_params` (22), not adjacent to
  `template_uuid`. That gap is expected and is not a sign this DDL is
  missing a column.

  ### The `source_type` DB-literal-default mismatch — not a bug to fix here

  `source_type`'s DB column default really is the retired string
  `'newsletters_list'::character varying` (core `V152`'s literal `CREATE
  TABLE`/`ALTER TABLE` text, adopted verbatim below) — `newsletters_list`
  as a `source_type` no longer exists as a valid audience source (see
  `PhoenixKit.Newsletters.Broadcast`'s own moduledoc comment on the field).
  `Broadcast.changeset/2`'s Ecto-level default is `"crm_list"`, which is
  what every INSERT going through that changeset actually uses; the raw DB
  default only matters for a hypothetical INSERT that bypasses the
  changeset entirely and omits the column. This mismatch is core-owned DDL,
  already documented as deliberate at the schema level, and out of scope
  for a newsletters-side migration change — V1 adopts the column
  byte-for-byte, default included.

  ### `recipient_email`'s `citext` extension always resolves to `public`

  `phoenix_kit_newsletters_deliveries.recipient_email` is `public.citext` —
  schema-qualified to `public` literally, regardless of the install's
  `prefix`, and not through `Helpers.qualify_table/2` or any prefix
  interpolation. `Helpers.ensure_extension!/1` always runs a bare `CREATE
  EXTENSION IF NOT EXISTS citext` with no `SCHEMA` clause, so the `citext`
  type itself is created wherever the connection's default schema search
  resolves it — `public` on every install this project supports, even one
  whose tables live under a named `prefix`. Core's own `V152` source emits
  the column as a bare, unqualified `CITEXT`; the literal `public.citext`
  spelling below is what core's `ExpectedSchema` manifest's structured
  `revisions` field records as the resolved type (Postgres's catalog
  reports the extension type with its installation schema), and this
  chain's column-shape test compares against that structured field, not
  the bare migration-source text — so the DDL below must spell it the same
  way to stay byte-for-byte adopted.

  ### Guards are semantic, not name-based — a real host discovery

  A host-level rename migration exists in the wild (a real host's own
  `rename_mailing_to_newsletters` migration) that renamed both tables from `phoenix_kit_mailing_broadcasts`/`_deliveries` to their
  current `phoenix_kit_newsletters_*` names — but a Postgres `ALTER TABLE
  ... RENAME TO` does not rename the table's own constraints or indexes.
  Every V135-era object on that host still carries its ORIGINAL name:
  `phoenix_kit_mailing_broadcasts_pkey` (not
  `phoenix_kit_newsletters_broadcasts_pkey`), `fk_mailing_broadcasts_created_by`/
  `fk_mailing_broadcasts_template`/`fk_mailing_deliveries_broadcast`/
  `fk_mailing_deliveries_user` (not the `fk_newsletters_*` names), and
  `idx_mailing_broadcasts_scheduled_at`/`_status`/
  `idx_mailing_deliveries_broadcast`/`_message_id`/`_status`/`_user` (not
  `idx_newsletters_*`). Every object introduced at `V152` or later
  (`idx_newsletters_broadcasts_crm_list`, `idx_newsletters_deliveries_crm_contact`,
  the three `idx_newsletters_deliveries_uniq_broadcast_*` indexes, both CHECK
  constraints) DOES carry its core `newsletters`-flavoured name on that same
  host, because core's own `V152`/`V155`/`V158` source hardcodes those names
  directly in `ALTER TABLE ... ADD CONSTRAINT`/`CREATE INDEX` text — a name
  literal in a later migration is unaffected by what an earlier, unrelated
  rename did to older objects' names.

  A first version of this chain guarded every constraint/index **by name**
  (`WHERE c.conname = 'phoenix_kit_newsletters_broadcasts_pkey'`), which is
  exactly the sibling chains' own pattern — but on a host in the state above,
  that guard's `NOT EXISTS` is TRUE (no constraint has that exact name), so
  `up/1` tries to `ADD CONSTRAINT phoenix_kit_newsletters_broadcasts_pkey
  PRIMARY KEY (uuid)` on a table that already has a (differently-named)
  primary key — Postgres rejects a second one outright
  (`multiple primary keys for table ... are not allowed`). The FK and index
  guards have the same defect in a quieter form: they would not error, they
  would silently ADD A SECOND, DUPLICATE constraint/index under the new
  name alongside the still-present legacy one — this exact failure mode was
  already observed on the same host for `phoenix_kit_posts` (3 duplicate
  UNIQUE indexes left behind by a name-based guard).

  Every guard below is therefore **semantic**: it asks Postgres "does this
  table already have a primary key" / "does this table already have a
  foreign key from this column to this target table" / "does this table
  already have an index on these columns with this uniqueness and this
  partial predicate" — via `pg_constraint`/`pg_index` joined through
  `'schema.table'::regclass` (which resolves the table by its CURRENT name
  regardless of any past rename, since renaming a table never changes its
  OID) — and only falls back to creating the object under this chain's own
  canonical name when truly nothing matching exists, by any name. A
  `CREATE INDEX`/`CREATE UNIQUE INDEX` statement is still wrapped in its own
  guard (via `EXECUTE` inside the `DO $$ ... $$` block) rather than left as
  a bare `CREATE INDEX IF NOT EXISTS <name> ...`, because `IF NOT EXISTS`
  only checks for that literal name — it does nothing to stop a second,
  differently-named index with an identical definition from being created,
  which is precisely the `phoenix_kit_posts` duplication above. The two
  CHECK guards match by name OR by an identical `pg_get_constraintdef`
  text, as a defense-in-depth measure — no host has actually been observed
  with a differently-named `newsletters`-owned CHECK constraint (both were
  introduced by core at `V152`/`V158`, well after the only rename event
  found in the wild, so they were always created under their current name),
  but the semantic fallback costs nothing and closes the same class of bug
  if one is ever discovered.

  A dedicated test (`migrations_renamed_host_test.exs`) reproduces this
  exact host shape — copies of both tables with every V135-era
  constraint/index renamed to its `phoenix_kit_mailing_*` equivalent — and
  runs a real `up/1` through `Ecto.Migration.Runner` against it: no error,
  no duplicate constraint or index of any kind, and the version marker
  still lands correctly.

  ### Phase 0 — this V1 adopts, and changes NOTHING

  `CREATE TABLE IF NOT EXISTS` shape-identical to core's `V135`-through-
  `V158` baseline, under core's exact object names (both pkeys, both
  CHECKs, every index, every FK), then a **namespaced** marker stamp on the
  anchor table (`pknl_schema:1` — an adopted table may already carry a
  foreign comment, so the reader must treat prose as version 0, never crash
  on it, never assume it means V1). Because the shape is unchanged, core's
  `ExpectedSchema` manifest stays accurate for every column of both tables:
  **no core release is required and there is no release-ordering hazard.**
  This package releases alone.

  ### Phase 1 — the first real shape change (V2+) is when core must move too

  Before shipping a version that changes either table's shape:

    1. add the objects that version alters to core's manifest generator's
       `@excluded_exact` (`dev_docs/squash/generate_baseline.exs`) and
       regenerate `ExpectedSchema`;
    2. raise this package's `:phoenix_kit` floor to the release that ships
       that regenerated manifest.

  Skipping step 1 means `mix phoenix_kit.repair` restores the old shape
  after every run, silently undoing the new version.

  ### Phase 2 — creation leaves core's baseline at the next squash cycle

  When core cuts its next baseline, module-owned tables are simply not
  included: fresh installs from then on get both
  `phoenix_kit_newsletters_*` tables from THIS chain's V1 — which is why
  V1's `up/1` ensures the `uuid_generate_v7()` function (and its
  `pgcrypto` extension, plus `citext` for `recipient_email`) exist rather
  than assuming core's chain already provided them, and why the `CREATE
  TABLE` statements must already be the full, correct definition on their
  own, not merely a shape-matching no-op for an already-existing table.
  Existing installs are untouched — a baseline squash only affects fresh
  installs and below-floor bridging.

  ## What must NEVER happen

  No conditional core migration of the form "module absent → drop the
  tables" — that is nondeterministic (depends on which packages are
  compiled in) and destroys data on a host that merely removed the
  package. Removing this module's data is a human, manual step — see
  README.md "Removing this module" for the operator SQL. There is
  deliberately no automated uninstall path, and `down/1` NEVER drops
  either table for ANY target version, including `0` — it only unstamps
  (or re-stamps) the marker on the anchor table. The rows are every host's
  real broadcast history and per-recipient delivery/bounce tracking;
  rolling back this module's chain must not destroy any of them.

  The migrated version is tracked as a `pknl_schema:<N>` COMMENT on
  `phoenix_kit_newsletters_broadcasts`. A marker-less table, or one
  carrying a foreign (non-`pknl_schema:`) comment, reads as version 0 —
  the core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @marker_prefix "pknl_schema:"

  @broadcasts "phoenix_kit_newsletters_broadcasts"
  @deliveries "phoenix_kit_newsletters_deliveries"

  # The single table this chain's marker lives on — this module's own hub
  # table, not `deliveries` (see the moduledoc for why). Deliveries shares
  # this chain's version; it carries no marker of its own.
  @version_table @broadcasts

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The version a bare, freshly-created set of tables is at (Phase 2 — a
  future install whose core baseline no longer creates these tables).
  """
  @spec initial_version() :: pos_integer()
  def initial_version, do: @initial_version

  @doc """
  The table carrying the `pknl_schema:<N>` marker for the whole 2-table chain.

  Not part of the protocol `mix phoenix_kit.update` calls. Exported so an
  auditor (`mix phoenix_kit_hello_world.audit_migrations`) can verify the
  marker is really a number without hard-coding this table's name.
  """
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies every chain version up to `opts[:version]` (default
  `current_version/0`). Migration-context only — re-reads the installed
  version via `migrated_version/1` before making any change, so a database
  already at (or ahead of) the target does nothing.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      # Don't assume core's chain ran first (Phase 2): `uuid_generate_v7()`
      # is built on pgcrypto's `gen_random_bytes`, and
      # `ensure_uuid_v7_function/1` does not install extensions — without
      # the first calls the function is created and then fails on the
      # first insert, and `recipient_email` needs citext to exist before
      # its CREATE TABLE runs.
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_extension!("citext")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration-context only.
  Never drops a table or a row in either of the 2, for any target — see
  the moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The version currently installed, read INSIDE a migration — through
  `Ecto.Migration`'s own `repo()`. No rescue: inside a migration a version
  that cannot be read must abort the transaction, never be guessed at.
  `up/1` and `down/1` call this — never `migrated_version_runtime/1` —
  before making any change.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  Runtime-safe reader — the one `mix phoenix_kit.update` calls, from a Mix
  task with no migrator running, through PhoenixKit's configured repo
  instead of `Ecto.Migration`'s.

  An invalid prefix is re-raised, matching core's own reader: `0` means
  "not installed here", so reporting it for a bad prefix would tell the
  operator something false and send the updater off to install a schema
  over live data. Genuine unreachability still yields `0`, which is safe
  only because `up/1` re-reads the version in migration context before
  touching anything — a wrong `0` costs a redundant migration file, never
  wrong DDL.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test suite parses these statements to prove that the object
  names are core's `V135`-through-`V158` names, that the `CREATE TABLE`
  stays shape-identical to core's `ExpectedSchema` manifest, that every
  varchar width is its owning schema's `column_widths/0`, that `list_uuid`
  and its FK/index never reappear, and that nothing here can drop a table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure adoption step across both
  tables.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)

    if target == 0 do
      []
    else
      v1_statements(prefix, target)
    end
  end

  @doc """
  The SQL `down/1` executes, as data (marker bookkeeping only, on the
  anchor table). V1 changes no shape of its own — it is pure adoption — so
  there is nothing to drop beyond the marker; both tables and every row in
  them are left untouched, for any target including `0`.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)
    qualified = Helpers.qualify_table(@version_table, prefix)

    if target > 0 do
      ["COMMENT ON TABLE #{qualified} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{qualified} IS NULL"]
    end
  end

  # ── V1 statement builder ────────────────────────────────────────────────

  defp v1_statements(prefix, target) do
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    email_templates = Helpers.qualify_table("phoenix_kit_email_templates", prefix)
    uuid_default = Helpers.uuid_v7_call(prefix)

    q_broadcasts = Helpers.qualify_table(@broadcasts, prefix)
    q_deliveries = Helpers.qualify_table(@deliveries, prefix)

    bw = Broadcast.column_widths()
    dw = Delivery.column_widths()

    tables = [
      """
      CREATE TABLE IF NOT EXISTS #{q_broadcasts} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "subject" character varying(#{bw.subject}) NOT NULL,
        "markdown_body" text,
        "html_body" text,
        "text_body" text,
        "template_uuid" uuid,
        "status" character varying(#{bw.status}) DEFAULT 'draft'::character varying NOT NULL,
        "scheduled_at" timestamp with time zone,
        "sent_at" timestamp with time zone,
        "total_recipients" integer DEFAULT 0 NOT NULL,
        "sent_count" integer DEFAULT 0 NOT NULL,
        "delivered_count" integer DEFAULT 0 NOT NULL,
        "opened_count" integer DEFAULT 0 NOT NULL,
        "bounced_count" integer DEFAULT 0 NOT NULL,
        "created_by_user_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "send_profile_uuid" uuid,
        "source_type" character varying(#{bw.source_type}) DEFAULT 'newsletters_list'::character varying NOT NULL,
        "crm_list_uuid" uuid,
        "source_params" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "attachments" jsonb DEFAULT '[]'::jsonb NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_deliveries} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "broadcast_uuid" uuid NOT NULL,
        "user_uuid" uuid,
        "status" character varying(#{dw.status}) DEFAULT 'pending'::character varying NOT NULL,
        "sent_at" timestamp with time zone,
        "delivered_at" timestamp with time zone,
        "opened_at" timestamp with time zone,
        "error" text,
        "message_id" character varying(#{dw.message_id}),
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "recipient_email" public.citext,
        "crm_contact_uuid" uuid
      )
      """
    ]

    pkeys = [
      pkey_guard(@broadcasts, q_broadcasts),
      pkey_guard(@deliveries, q_deliveries)
    ]

    checks = [
      check_guard(
        q_broadcasts,
        "phoenix_kit_newsletters_broadcasts_attachments_is_array",
        "jsonb_typeof(attachments) = 'array'",
        "CHECK ((jsonb_typeof(attachments) = 'array'::text))"
      ),
      check_guard(
        q_deliveries,
        "phoenix_kit_newsletters_deliveries_recipient_check",
        "(user_uuid IS NOT NULL OR recipient_email IS NOT NULL) AND NOT (user_uuid IS NOT NULL AND crm_contact_uuid IS NOT NULL)",
        "CHECK ((((user_uuid IS NOT NULL) OR (recipient_email IS NOT NULL)) AND (NOT ((user_uuid IS NOT NULL) AND (crm_contact_uuid IS NOT NULL)))))"
      )
    ]

    indexes = [
      index_guard(
        "idx_newsletters_broadcasts_status",
        q_broadcasts,
        false,
        "btree",
        ["status"],
        nil
      ),
      index_guard(
        "idx_newsletters_broadcasts_scheduled_at",
        q_broadcasts,
        false,
        "btree",
        ["scheduled_at"],
        "(scheduled_at IS NOT NULL)"
      ),
      index_guard(
        "idx_newsletters_broadcasts_crm_list",
        q_broadcasts,
        false,
        "btree",
        ["crm_list_uuid"],
        "(crm_list_uuid IS NOT NULL)"
      ),
      index_guard(
        "idx_newsletters_deliveries_broadcast",
        q_deliveries,
        false,
        "btree",
        ["broadcast_uuid"],
        nil
      ),
      index_guard(
        "idx_newsletters_deliveries_user",
        q_deliveries,
        false,
        "btree",
        ["user_uuid"],
        nil
      ),
      index_guard(
        "idx_newsletters_deliveries_message_id",
        q_deliveries,
        true,
        "btree",
        ["message_id"],
        "(message_id IS NOT NULL)"
      ),
      index_guard(
        "idx_newsletters_deliveries_status",
        q_deliveries,
        false,
        "btree",
        ["status"],
        nil
      ),
      index_guard(
        "idx_newsletters_deliveries_crm_contact",
        q_deliveries,
        false,
        "btree",
        ["crm_contact_uuid"],
        nil
      ),
      index_guard(
        "idx_newsletters_deliveries_uniq_broadcast_user",
        q_deliveries,
        true,
        "btree",
        ["broadcast_uuid", "user_uuid"],
        "(user_uuid IS NOT NULL)"
      ),
      index_guard(
        "idx_newsletters_deliveries_uniq_broadcast_contact",
        q_deliveries,
        true,
        "btree",
        ["broadcast_uuid", "crm_contact_uuid"],
        "(crm_contact_uuid IS NOT NULL)"
      ),
      index_guard(
        "idx_newsletters_deliveries_uniq_broadcast_email",
        q_deliveries,
        true,
        "btree",
        ["broadcast_uuid", "recipient_email"],
        "(recipient_email IS NOT NULL)"
      )
    ]

    fks = [
      fk_guard(
        q_broadcasts,
        "fk_newsletters_broadcasts_created_by",
        "created_by_user_uuid",
        users,
        "SET NULL"
      ),
      fk_guard(
        q_broadcasts,
        "fk_newsletters_broadcasts_template",
        "template_uuid",
        email_templates,
        "SET NULL"
      ),
      fk_guard(
        q_deliveries,
        "fk_newsletters_deliveries_broadcast",
        "broadcast_uuid",
        q_broadcasts,
        "CASCADE"
      ),
      fk_guard(
        q_deliveries,
        "fk_newsletters_deliveries_user",
        "user_uuid",
        users,
        "CASCADE"
      )
    ]

    marker = ["COMMENT ON TABLE #{q_broadcasts} IS '#{@marker_prefix}#{target}'"]

    tables ++ pkeys ++ checks ++ indexes ++ fks ++ marker
  end

  # Semantic: "does this table already have ANY primary key", not "does a
  # constraint with this exact name exist" — a table whose PK predates a
  # host-level table rename (renaming a table never renames its own
  # constraints) still has a real, functioning primary key under its old
  # name, and adding a second one is a hard Postgres error, not a silent
  # duplicate. `regclass` resolves `qualified` by the table's CURRENT name
  # regardless of that history, since a rename never changes the OID.
  defp pkey_guard(table, qualified) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{qualified}'::regclass AND contype = 'p'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid);
      END IF;
    END
    $$
    """
  end

  # Matches by name (core has always created both of this chain's CHECK
  # constraints under their current name — they were introduced at V152/V158,
  # after the only rename event found in the wild) OR by an identical
  # `pg_get_constraintdef` text, as a defense-in-depth fallback that costs
  # nothing if no host is ever found with a differently-named one.
  # `canonical_def` is the exact text Postgres's own `pg_get_constraintdef`
  # renders for `check_expr` (verified against a live catalog, not guessed —
  # Postgres re-parenthesizes fully and deterministically, so a literal
  # string compare is reliable here).
  defp check_guard(qualified, constraint_name, check_expr, canonical_def) do
    # `canonical_def` is embedded as a single-quoted SQL string literal, so
    # any single quote it contains (e.g. the 'array'::text literal inside
    # the attachments CHECK's own canonical text) must be SQL-escaped by
    # doubling it, or the literal terminates early and the rest is parsed
    # as SQL — exactly the syntax error a plain `#{canonical_def}` produced
    # here originally.
    escaped_canonical_def = String.replace(canonical_def, "'", "''")

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{qualified}'::regclass
          AND contype = 'c'
          AND (conname = '#{constraint_name}' OR pg_get_constraintdef(oid) = '#{escaped_canonical_def}')
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} CHECK (#{check_expr});
      END IF;
    END
    $$
    """
  end

  # Semantic: "does this table already have a foreign key from `column` to
  # `references`", matched via `conrelid`/`confrelid` (both resolved through
  # `regclass`, immune to either table having been renamed) and `conkey`
  # (the source column, by attnum — immune to the constraint's own name).
  # A name-based guard would silently ADD A DUPLICATE FK under the new name
  # next to an already-functioning, differently-named one — this is not
  # hypothetical, the same defect already left 3 duplicate UNIQUE indexes on
  # a real host for a sibling module (`phoenix_kit_posts`) before this fix.
  #
  # Deliberately NOT part of the match: `on_delete` (the referential action).
  # This is an ADOPTION guard, not a shape-repair tool — if a host's
  # existing FK (found by table/column/target alone) already has a
  # different `ON DELETE` behavior than the `on_delete` argument below
  # would create, this guard leaves it exactly as it is rather than trying
  # to converge the two. A real disagreement there would be a legitimate
  # V2+ shape change (with its own manifest/floor implications, see the
  # moduledoc's Phase 1), never something V1's silent adoption should paper
  # over by dropping and re-adding someone's live constraint.
  defp fk_guard(qualified, constraint_name, column, references, on_delete) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{qualified}'::regclass
          AND contype = 'f'
          AND confrelid = '#{references}'::regclass
          AND conkey = ARRAY[(
            SELECT attnum FROM pg_attribute
            WHERE attrelid = '#{qualified}'::regclass AND attname = '#{column}'
          )]::smallint[]
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} FOREIGN KEY (#{column}) REFERENCES #{references}(uuid) ON DELETE #{on_delete};
      END IF;
    END
    $$
    """
  end

  # Semantic: "does this table already have an index on these columns, in
  # this order, with this uniqueness and this partial predicate" — NOT
  # merely "is there an index with this exact name". A bare
  # `CREATE INDEX IF NOT EXISTS <name> ...` only guards against its own
  # literal name; it does nothing to stop a second, differently-named index
  # with an identical definition (the `phoenix_kit_posts` duplicate-index
  # incident this guard exists to prevent here). `i.indkey::int2[]` resolved
  # to column names via `pg_attribute`, in index-column order, compared
  # against the expected column list; `pg_get_expr(i.indpred, i.indrelid)`
  # is Postgres's own canonical rendering of a partial index's predicate
  # (NULL when the index isn't partial) — both sides of that comparison are
  # verified-live text, not guessed. `CREATE INDEX` is DDL, not a plain SQL
  # statement PL/pgSQL can run directly inside `IF`, hence `EXECUTE`.
  #
  # `i.indexprs IS NULL` and the `array_length` check below both exist for
  # the same real bug, caught by testing against a live catalog rather than
  # reading the query: an EXPRESSION index (e.g. `ON t (status,
  # lower(error))`) stores `0` — not a real attnum — in `indkey` for its
  # expression column. `pg_attribute` has no row for attnum `0`, so the
  # `JOIN pg_attribute` above silently DROPS that position instead of
  # erroring, shortening the aggregated array from `{status, <expr
  # position>}` down to just `{status}` — which then equals `ARRAY['status']`
  # and gets misread as "the plain `idx_newsletters_deliveries_status`
  # index already exists" even though the real index found is an unrelated
  # expression index that only happens to share one column name. Verified
  # live: `CREATE INDEX ON t (status, lower(error))` produces exactly this
  # `{status}` aggregate with `indexprs IS NOT NULL` and
  # `array_length(indkey, 1) = 2`. `indexprs IS NULL` alone would already
  # exclude every expression index (none of this chain's own indexes are
  # ever expression-based); the `array_length` check is kept alongside it
  # as an independent guard against the same join silently dropping a row
  # for any other reason.
  defp index_guard(name, qualified, unique?, method, columns, predicate) do
    columns_sql = Enum.join(columns, ", ")
    where_clause = if predicate, do: " WHERE #{predicate}", else: ""
    unique_sql = if unique?, do: "UNIQUE ", else: ""
    columns_array = columns |> Enum.map_join(", ", &"'#{&1}'")
    column_count = length(columns)

    predicate_condition =
      if predicate do
        "pg_get_expr(i.indpred, i.indrelid) = '#{String.replace(predicate, "'", "''")}'"
      else
        "i.indpred IS NULL"
      end

    # The predicate is compared above as a single-quoted SQL literal, and the
    # whole dynamic statement below is embedded inside a single-quoted
    # `EXECUTE '...'` argument, so any single quote either contains (none of
    # this chain's own column names/predicates have one today, but a
    # predicate string is caller-supplied text, not a fixed literal) must
    # be SQL-escaped by doubling it — the same rule `check_guard`'s
    # `canonical_def` needed, and for the same reason: an unescaped quote
    # would terminate the `EXECUTE` argument early and the remainder would
    # be parsed as SQL instead of stored as string content.
    create_index_sql =
      "CREATE #{unique_sql}INDEX IF NOT EXISTS #{name} ON #{qualified} USING #{method} (#{columns_sql})#{where_clause}"

    escaped_create_index_sql = String.replace(create_index_sql, "'", "''")

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_am am ON am.oid = ic.relam
        WHERE i.indrelid = '#{qualified}'::regclass
          AND i.indisunique = #{unique?}
          AND am.amname = '#{method}'
          AND i.indexprs IS NULL
          AND array_length(i.indkey::int2[], 1) = #{column_count}
          AND #{predicate_condition}
          AND (
            SELECT array_agg(a.attname ORDER BY k.ord)
            FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
          ) = ARRAY[#{columns_array}]::name[]
      ) THEN
        EXECUTE '#{escaped_create_index_sql}';
      END IF;
    END
    $$
    """
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = validated_prefix(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  defp read_version(repo, prefix) do
    if table_exists?(repo, prefix) do
      repo |> table_comment(prefix) |> parse_version()
    else
      0
    end
  end

  defp table_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1 AND table_schema = $2
    )
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, error} -> raise error
    end
  end

  defp table_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitNewsletters.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # `phoenix_kit` is a normal (non-optional) dependency of this package, so
  # `Helpers` is always loaded — unlike customer_support's fallback branch,
  # there is no configuration where this module compiles without it.
  defp validated_prefix(prefix) do
    Helpers.validate_prefix!(prefix)
    prefix
  end
end
