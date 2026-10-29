defmodule PhoenixKitNewsletters.MigrationsLegacyNamesTest do
  @moduledoc """
  V3 of the chain gives the objects a pre-rename host kept under their old
  names (`phoenix_kit_mailing_*_pkey`, `fk_mailing_*`, `idx_mailing_*`) the
  names `PhoenixKit.Newsletters.ExpectedSchema` expects, so that
  `mix phoenix_kit.repair` / `doctor` find them where they are instead of
  reporting them missing and creating a second copy (or failing on a second
  primary key).

  Two fixtures:

    * a **renamed host**, built the way it came about: the pre-rename tables
      with every V135-era object under its old name, then the chain run from
      V1 to V3 (`RenamedHostFixture`);
    * the schema `PhoenixKit.TestSupport.ModuleChainCheck.build_alone/4`
      builds (core's tables, then this chain, so core's own pass and the
      module's manifest see a real install), with chosen objects renamed back
      to their old names and the marker lowered to 2, which is where a host
      that has not yet run `mix phoenix_kit.update` stands.

  The second schema is built once; each test works in a sandbox transaction
  that rolls its DDL back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Newsletters.ExpectedSchema
  alias PhoenixKit.TestSupport.ModuleChainCheck
  alias PhoenixKitNewsletters.Migrations
  alias PhoenixKitNewsletters.RenamedHostFixture
  alias PhoenixKitNewsletters.Test.Repo

  @moduletag :integration
  @moduletag :requires_core_expected_schema
  @moduletag timeout: :timer.minutes(5)

  @app :phoenix_kit_newsletters
  @modules %{@app => %{manifest: ExpectedSchema, migrations: Migrations}}

  @broadcasts "phoenix_kit_newsletters_broadcasts"
  @deliveries "phoenix_kit_newsletters_deliveries"

  # The twelve objects a renamed host holds under their old names: both
  # primary keys, the four foreign keys and the six indexes core's V135 built.
  @pkeys [
    {@broadcasts, "phoenix_kit_newsletters_broadcasts_pkey"},
    {@deliveries, "phoenix_kit_newsletters_deliveries_pkey"}
  ]
  @fks [
    {@broadcasts, "fk_newsletters_broadcasts_created_by"},
    {@broadcasts, "fk_newsletters_broadcasts_template"},
    {@deliveries, "fk_newsletters_deliveries_broadcast"},
    {@deliveries, "fk_newsletters_deliveries_user"}
  ]
  @indexes [
    "idx_newsletters_broadcasts_scheduled_at",
    "idx_newsletters_broadcasts_status",
    "idx_newsletters_deliveries_broadcast",
    "idx_newsletters_deliveries_message_id",
    "idx_newsletters_deliveries_status",
    "idx_newsletters_deliveries_user"
  ]

  defmodule RunMigration do
    @moduledoc false
    use Ecto.Migration

    def up do
      {prefix, version} = Process.get(:nl_run)
      PhoenixKitNewsletters.Migrations.up(prefix: prefix, version: version)
    end

    def down do
      {prefix, version} = Process.get(:nl_run)
      PhoenixKitNewsletters.Migrations.down(prefix: prefix, version: version)
    end
  end

  setup_all do
    # Core's chain reads the repo from config while it builds, and the
    # module's runtime version reader goes through it.
    previous_repo = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, Repo)

    schema = "nlln_" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _tables} = ModuleChainCheck.build_alone(Repo, Migrations, schema)

    on_exit(fn ->
      if previous_repo,
        do: Application.put_env(:phoenix_kit, :repo, previous_repo),
        else: Application.delete_env(:phoenix_kit, :repo)

      Sandbox.mode(Repo, :auto)
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      Sandbox.mode(Repo, :manual)
    end)

    %{schema: schema}
  end

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  # ── a host that renamed its tables the old way ─────────────────────────

  describe "a host whose tables were renamed by its own migration" do
    @old "nlln_oldhost"

    setup do
      RenamedHostFixture.create!(@old)

      # The stub stands in for a table V2 would copy rows from; with it gone
      # the old template foreign key goes too, and V2 builds its own.
      Repo.query!("DROP TABLE #{@old}.phoenix_kit_email_templates CASCADE")
      :ok
    end

    test "running the chain to V3 gives every object its canonical name and keeps every row" do
      %{rows: [[broadcast]]} =
        Repo.query!("INSERT INTO #{@old}.#{@broadcasts} (subject) VALUES ('kept') RETURNING uuid")

      Repo.query!(
        "INSERT INTO #{@old}.#{@deliveries} (broadcast_uuid, recipient_email) VALUES ($1, 'a@example.com')",
        [broadcast]
      )

      before = oids(@old)
      assert Enum.any?(names(@old), &(&1 =~ "mailing"))

      run(@old, :up, 3)

      assert names(@old) == canonical_names(@old)
      refute Enum.any?(names(@old), &(&1 =~ "mailing"))
      assert Migrations.migrated_version_runtime(prefix: @old) == 3

      # Renamed, not rebuilt: the objects the host already had are the same
      # objects.
      assert before -- oids(@old) == []

      assert %{rows: [["kept"]]} = Repo.query!("SELECT subject FROM #{@old}.#{@broadcasts}")
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{@old}.#{@deliveries}")
    end
  end

  # ── the module's manifest on a host that has not updated yet / has ─────

  describe "a host whose objects carry their old names" do
    setup %{schema: schema} do
      to_legacy!(schema, @pkeys ++ @fks, @indexes)
      set_marker!(schema, 2)
      :ok
    end

    test "is reported as behind, never repaired, until the chain reaches V3", %{schema: schema} do
      before = names(schema)

      assert [%{kind: :module_behind, severity: :info}] = schema |> verify() |> module_findings()

      {:ok, _report} = Repair.repair(prefix: schema, repo: Repo, module_manifests: @modules)

      assert names(schema) == before
      assert Enum.count(before, &(&1 =~ "mailing")) == 12
    end

    test "has all twelve renamed by V3, and the manifest then finds nothing missing", %{
      schema: schema
    } do
      before_oids = oids(schema)

      run(schema, :up, 3)

      assert names(schema) == canonical_names(schema)
      assert oids(schema) == before_oids
      assert Migrations.migrated_version_runtime(prefix: schema) == 3

      assert [] = schema |> verify() |> module_findings()
    end

    test "is left alone by repair once V3 has run", %{schema: schema} do
      run(schema, :up, 3)
      after_v3 = names(schema)

      {:ok, report} = Repair.repair(prefix: schema, repo: Repo, module_manifests: @modules)

      assert [] = module_findings(report)
      assert names(schema) == after_v3
      refute Enum.any?(after_v3, &(&1 =~ "mailing"))
    end

    test "can run V3 again: the second run changes nothing and says nothing", %{schema: schema} do
      run(schema, :up, 3)
      once = names(schema)
      set_marker!(schema, 2)

      log = run(schema, :up, 3)

      assert names(schema) == once
      refute log =~ ~r/V3: (idx_|fk_|phoenix_kit_newsletters_)\w+ (is already|has several)/
    end

    test "going back down to 2 moves the marker and nothing else", %{schema: schema} do
      run(schema, :up, 3)
      renamed = names(schema)

      run(schema, :down, 2)

      assert Migrations.migrated_version_runtime(prefix: schema) == 2
      assert names(schema) == renamed
    end
  end

  describe "a host with some objects renamed and some not" do
    test "renames only the old ones", %{schema: schema} do
      to_legacy!(schema, [hd(@pkeys), Enum.at(@fks, 3)], [
        Enum.at(@indexes, 1),
        Enum.at(@indexes, 4)
      ])

      set_marker!(schema, 2)
      before_oids = oids(schema)

      assert Enum.count(names(schema), &(&1 =~ "mailing")) == 4

      run(schema, :up, 3)

      assert names(schema) == canonical_names(schema)
      assert oids(schema) == before_oids
    end
  end

  describe "a fresh install" do
    test "has nothing for V3 to do", %{schema: schema} do
      before = names(schema)
      before_oids = oids(schema)
      set_marker!(schema, 2)

      log = run(schema, :up, 3)

      assert names(schema) == before
      assert oids(schema) == before_oids
      assert Migrations.migrated_version_runtime(prefix: schema) == 3
      refute log =~ ~r/V3: (idx_|fk_|phoenix_kit_newsletters_)\w+ (is already|has several)/
      assert [] = schema |> verify() |> module_findings()
    end
  end

  # ── what V3 must not touch ─────────────────────────────────────────────

  describe "when the canonical name is not free, or the match is not unique" do
    test "an object that already exists under both names is renamed to neither, and V3 says so",
         %{schema: schema} do
      # The status index, twice: the canonical one and an identical one under
      # the old name (what a name-based repair run leaves behind).
      Repo.query!(
        ~s[CREATE INDEX idx_mailing_broadcasts_status ON "#{schema}".#{@broadcasts} USING btree (status)]
      )

      set_marker!(schema, 2)
      before = names(schema)

      log = run(schema, :up, 3)

      assert names(schema) == before
      assert "idx_mailing_broadcasts_status" in names(schema)
      assert "idx_newsletters_broadcasts_status" in names(schema)

      assert log =~
               ~r/idx_newsletters_broadcasts_status is already in use.*idx_mailing_broadcasts_status/s
    end

    test "a canonical name held by an unrelated object is never renamed over", %{schema: schema} do
      Repo.query!(
        ~s(ALTER INDEX "#{schema}".idx_newsletters_broadcasts_status RENAME TO idx_mailing_broadcasts_status)
      )

      # Something else now owns the canonical name: an index on another column.
      Repo.query!(
        ~s[CREATE INDEX idx_newsletters_broadcasts_status ON "#{schema}".#{@broadcasts} USING btree (subject)]
      )

      set_marker!(schema, 2)
      before = names(schema)

      log = run(schema, :up, 3)

      assert names(schema) == before

      assert log =~
               ~r/idx_newsletters_broadcasts_status is already in use.*idx_mailing_broadcasts_status/s
    end

    test "several equivalents under other names are all left alone, and V3 says so", %{
      schema: schema
    } do
      Repo.query!(
        ~s(ALTER INDEX "#{schema}".idx_newsletters_broadcasts_status RENAME TO idx_mailing_broadcasts_status)
      )

      Repo.query!(
        ~s[CREATE INDEX my_status_index ON "#{schema}".#{@broadcasts} USING btree (status)]
      )

      set_marker!(schema, 2)
      before = names(schema)

      log = run(schema, :up, 3)

      assert names(schema) == before
      assert "idx_mailing_broadcasts_status" in names(schema)
      assert "my_status_index" in names(schema)

      assert log =~
               ~r/idx_newsletters_broadcasts_status has several equivalents.*my_status_index/s
    end

    test "an object that is not the same thing is not renamed", %{schema: schema} do
      # A unique index on the same column is a different index: the chain
      # (V1's guard, which runs first) builds the canonical one next to it, and
      # V3 leaves both alone.
      Repo.query!(~s(DROP INDEX "#{schema}".idx_newsletters_broadcasts_status))

      Repo.query!(
        ~s[CREATE UNIQUE INDEX idx_mailing_broadcasts_status ON "#{schema}".#{@broadcasts} USING btree (status)]
      )

      set_marker!(schema, 2)

      log = run(schema, :up, 3)

      assert %{rows: [[true]]} =
               Repo.query!(
                 "SELECT indisunique FROM pg_index WHERE indexrelid = to_regclass($1)",
                 ["#{schema}.idx_mailing_broadcasts_status"]
               )

      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT indisunique FROM pg_index WHERE indexrelid = to_regclass($1)",
                 ["#{schema}.idx_newsletters_broadcasts_status"]
               )

      refute log =~ ~r/V3: (idx_|fk_|phoenix_kit_newsletters_)\w+ (is already|has several)/
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Everything V3 looks at, as one sorted list: the primary and foreign key
  # constraints of the two tables, and the indexes no constraint owns (a
  # primary key's own index goes with the constraint's name).
  defp names(schema) do
    %{rows: constraints} =
      Repo.query!(
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = ANY($2) AND con.contype IN ('p', 'f')
        """,
        [schema, [@broadcasts, @deliveries]]
      )

    %{rows: indexes} =
      Repo.query!(
        """
        SELECT ic.relname FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = ANY($2)
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
        """,
        [schema, [@broadcasts, @deliveries]]
      )

    Enum.sort(Enum.map(constraints, &hd/1) ++ Enum.map(indexes, &hd/1))
  end

  # The objects' identities, whatever they are called.
  defp oids(schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.oid::bigint FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = ANY($2) AND con.contype IN ('p', 'f')
        UNION ALL
        SELECT i.indexrelid::bigint FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = ANY($2)
        """,
        [schema, [@broadcasts, @deliveries]]
      )

    rows |> Enum.map(&hd/1) |> Enum.sort()
  end

  # What `names/1` reads on an install whose objects all have the names the
  # manifest expects.
  defp canonical_names(schema) do
    indexes =
      for %{class: :index, id: "index:" <> name} <- ExpectedSchema.objects(schema),
          name =~ ~r/^idx_newsletters_(broadcasts|deliveries)_/,
          do: name

    constraints =
      for %{class: :constraint, id: "constraint:" <> id} = object <-
            ExpectedSchema.objects(schema),
          [table, name] = String.split(id, ".", parts: 2),
          table in [@broadcasts, @deliveries],
          shape(object).type in ["p", "f"],
          do: name

    Enum.sort(constraints ++ indexes)
  end

  defp shape(object), do: object.revisions |> List.last() |> elem(1)

  defp legacy(name), do: String.replace(name, "newsletters", "mailing")

  defp to_legacy!(schema, constraints, indexes) do
    for {table, name} <- constraints do
      Repo.query!(
        ~s(ALTER TABLE "#{schema}"."#{table}" RENAME CONSTRAINT #{name} TO #{legacy(name)})
      )
    end

    for name <- indexes do
      Repo.query!(~s(ALTER INDEX "#{schema}".#{name} RENAME TO #{legacy(name)}))
    end

    :ok
  end

  defp set_marker!(schema, version) do
    Repo.query!(~s(COMMENT ON TABLE "#{schema}".#{@broadcasts} IS 'pknl_schema:#{version}'))
  end

  # Runs the chain the way `mix phoenix_kit.update` does, in a migration, and
  # returns what it logged (the warnings V3 raises among it).
  defp run(prefix, direction, version) do
    Process.put(:nl_run, {prefix, version})

    capture_log(fn ->
      Runner.run(
        Repo,
        [],
        System.unique_integer([:positive]),
        RunMigration,
        :forward,
        direction,
        direction,
        log: :warning,
        log_migrations_sql: false
      )
    end)
  end

  defp verify(schema) do
    {:ok, report} = Repair.verify(prefix: schema, repo: Repo, module_manifests: @modules)
    report
  end

  defp module_findings(report) do
    report
    |> Repair.Report.findings()
    |> Enum.filter(& &1[:module])
  end
end
