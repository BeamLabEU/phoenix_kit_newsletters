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
  `phoenix_kit_newsletters_deliveries` are core's baseline: core's `V135`
  created both tables in their original shape, and `V145`, `V152`, `V155`,
  `V156` and `V158` each layered a further shape change on top (send
  profiles, CRM-sourced recipients, the recipient CHECK, dropping
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
  shape), these two tables were created directly by core's `V135` baseline
  itself — there is no pre-V135 predecessor that could have been squashed
  incorrectly, and `git log --all -- '*migration*'` in this repo confirms
  this module never shipped its own migration file before this one. A
  dedicated research pass (core's migration source across `V135`/`V145`/
  `V152`/`V155`/`V156`/`V158`, core's structured `ExpectedSchema.objects/1`
  `revisions` field, and a live, fully-migrated Postgres catalog query)
  confirmed, at high confidence, that the current live shape matches the
  literal migration-chain text exactly, column-for-column, with **zero
  discrepancies**. So V1 here is even more purely a no-op-shape adoption
  than either sibling case: `CREATE TABLE IF NOT EXISTS` (full final shape)
  + guarded PK + guarded CHECK(s) + `CREATE INDEX IF NOT EXISTS` + guarded
  FKs + the version-marker `COMMENT` — **no `ALTER TABLE ... ADD COLUMN IF
  NOT EXISTS` or `ALTER COLUMN ... DROP NOT NULL` safety-net section
  anywhere in this file.**

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

    pkeys =
      for {table, qualified} <- [{@broadcasts, q_broadcasts}, {@deliveries, q_deliveries}] do
        pkey_guard(table, qualified, prefix)
      end

    checks = [
      check_guard(
        @broadcasts,
        q_broadcasts,
        "phoenix_kit_newsletters_broadcasts_attachments_is_array",
        "jsonb_typeof(attachments) = 'array'",
        prefix
      ),
      check_guard(
        @deliveries,
        q_deliveries,
        "phoenix_kit_newsletters_deliveries_recipient_check",
        "(user_uuid IS NOT NULL OR recipient_email IS NOT NULL) AND NOT (user_uuid IS NOT NULL AND crm_contact_uuid IS NOT NULL)",
        prefix
      )
    ]

    indexes =
      [
        {"", "idx_newsletters_broadcasts_status", q_broadcasts, "btree", "status", nil},
        {"", "idx_newsletters_broadcasts_scheduled_at", q_broadcasts, "btree", "scheduled_at",
         "(scheduled_at IS NOT NULL)"},
        {"", "idx_newsletters_broadcasts_crm_list", q_broadcasts, "btree", "crm_list_uuid",
         "(crm_list_uuid IS NOT NULL)"},
        {"", "idx_newsletters_deliveries_broadcast", q_deliveries, "btree", "broadcast_uuid",
         nil},
        {"", "idx_newsletters_deliveries_user", q_deliveries, "btree", "user_uuid", nil},
        {"UNIQUE", "idx_newsletters_deliveries_message_id", q_deliveries, "btree", "message_id",
         "(message_id IS NOT NULL)"},
        {"", "idx_newsletters_deliveries_status", q_deliveries, "btree", "status", nil},
        {"", "idx_newsletters_deliveries_crm_contact", q_deliveries, "btree", "crm_contact_uuid",
         nil},
        {"UNIQUE", "idx_newsletters_deliveries_uniq_broadcast_user", q_deliveries, "btree",
         "broadcast_uuid, user_uuid", "(user_uuid IS NOT NULL)"},
        {"UNIQUE", "idx_newsletters_deliveries_uniq_broadcast_contact", q_deliveries, "btree",
         "broadcast_uuid, crm_contact_uuid", "(crm_contact_uuid IS NOT NULL)"},
        {"UNIQUE", "idx_newsletters_deliveries_uniq_broadcast_email", q_deliveries, "btree",
         "broadcast_uuid, recipient_email", "(recipient_email IS NOT NULL)"}
      ]
      |> Enum.map(fn {unique, name, table, method, columns, predicate} ->
        where_clause = if predicate, do: " WHERE #{predicate}", else: ""

        "CREATE #{unique_prefix(unique)}INDEX IF NOT EXISTS #{name} ON #{table} USING #{method} (#{columns})#{where_clause}"
      end)

    fks = [
      fk_guard(
        @broadcasts,
        q_broadcasts,
        "fk_newsletters_broadcasts_created_by",
        "created_by_user_uuid",
        users,
        "SET NULL",
        prefix
      ),
      fk_guard(
        @broadcasts,
        q_broadcasts,
        "fk_newsletters_broadcasts_template",
        "template_uuid",
        email_templates,
        "SET NULL",
        prefix
      ),
      fk_guard(
        @deliveries,
        q_deliveries,
        "fk_newsletters_deliveries_broadcast",
        "broadcast_uuid",
        q_broadcasts,
        "CASCADE",
        prefix
      ),
      fk_guard(
        @deliveries,
        q_deliveries,
        "fk_newsletters_deliveries_user",
        "user_uuid",
        users,
        "CASCADE",
        prefix
      )
    ]

    marker = ["COMMENT ON TABLE #{q_broadcasts} IS '#{@marker_prefix}#{target}'"]

    tables ++ pkeys ++ checks ++ indexes ++ fks ++ marker
  end

  defp unique_prefix("UNIQUE"), do: "UNIQUE "
  defp unique_prefix(""), do: ""

  defp pkey_guard(table, qualified, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{table}_pkey'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid);
      END IF;
    END
    $$
    """
  end

  defp check_guard(table, qualified, constraint_name, check_expr, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} CHECK (#{check_expr});
      END IF;
    END
    $$
    """
  end

  defp fk_guard(table, qualified, constraint_name, column, references, on_delete, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} FOREIGN KEY (#{column}) REFERENCES #{references}(uuid) ON DELETE #{on_delete};
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
