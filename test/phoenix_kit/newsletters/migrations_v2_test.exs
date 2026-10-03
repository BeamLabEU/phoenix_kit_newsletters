defmodule PhoenixKitNewsletters.MigrationsV2Test do
  use PhoenixKitNewsletters.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitNewsletters.Migrations
  alias PhoenixKitNewsletters.Test.Repo

  @moduledoc """
  V2 against real rows: the layouts table, the carry-over of the
  operator-authored email templates under their own uuids, and
  `broadcasts.template_uuid` moved from the email-templates table to the
  layouts table.

  Each test builds its own install in an isolated prefix schema inside the
  sandboxed transaction (Postgres DDL is transactional, so it all rolls
  back): stub `phoenix_kit_users`, an email-templates table in core's
  column shape, then this chain's own V1 — which creates both newsletters
  tables from nothing, FK to the email-templates table included — exactly
  the state an existing install is in before V2. The data is synthetic and
  shaped like a multilingual host: 3 operator layouts in 7 languages, system
  rows beside them, and 10 broadcasts.

  `async: false` — shares the migrator's sandbox connection, like
  `migrations_data_safety_test.exs`.
  """

  @prefix "nlv2_host"
  @bare "nlv2_bare"
  @languages ~w(en de es fr it pl ru)

  defmodule UpToOne do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitNewsletters.Migrations.up(prefix: "nlv2_host", version: 1)
    def down, do: :ok
  end

  defmodule UpToTwo do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitNewsletters.Migrations.up(prefix: "nlv2_host", version: 2)
    def down, do: :ok
  end

  defmodule DownToOne do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitNewsletters.Migrations.down(prefix: "nlv2_host", version: 1)
    def down, do: :ok
  end

  defmodule BareUpToTwo do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitNewsletters.Migrations.up(prefix: "nlv2_bare", version: 2)
    def down, do: :ok
  end

  describe "an install with operator templates and broadcasts" do
    setup do
      create_host(@prefix, email_templates?: true)
      run_migration(UpToOne)
      assert version(@prefix) == 1

      user = uuid()
      Repo.query!("INSERT INTO #{@prefix}.phoenix_kit_users (uuid) VALUES ($1)", [dump(user)])

      operator = [
        insert_template("welcome_layout", "active", false, user),
        insert_template("digest_layout", "active", false, uuid()),
        insert_template("promo_layout", "draft", false, nil)
      ]

      system = [
        insert_template("test_email", "active", true, nil),
        insert_template("magic_link", "active", true, nil)
      ]

      broadcasts =
        for i <- 1..10 do
          insert_broadcast("Issue #{i}", Enum.at(operator, rem(i, 3)))
        end

      {:ok, user: user, operator: operator, system: system, broadcasts: broadcasts}
    end

    test "copies every operator row under its own uuid, maps as they are",
         %{operator: operator, user: user} do
      templates_before =
        rows("SELECT * FROM #{@prefix}.phoenix_kit_email_templates ORDER BY uuid")

      run_migration(UpToTwo)
      assert version(@prefix) == 2

      layouts =
        query_maps("""
        SELECT uuid, name, display_name, subject, html_body, text_body, status, metadata,
               created_by_user_uuid
        FROM #{@prefix}.phoenix_kit_newsletters_layouts ORDER BY name
        """)

      assert Enum.map(layouts, & &1["uuid"]) |> Enum.sort() == Enum.sort(operator)
      assert Enum.map(layouts, & &1["name"]) == ~w(digest_layout promo_layout welcome_layout)

      welcome = Enum.find(layouts, &(&1["name"] == "welcome_layout"))
      assert Map.keys(welcome["html_body"]) |> Enum.sort() == Enum.sort(@languages)
      assert welcome["html_body"]["de"] == html("welcome_layout", "de")
      assert welcome["subject"]["fr"] == "{{subject}} (fr)"
      assert welcome["display_name"]["ru"] == "welcome_layout ru"
      assert welcome["text_body"]["pl"] == "welcome_layout pl {{content}}"
      assert welcome["status"] == "active"
      assert welcome["created_by_user_uuid"] == user
      assert welcome["metadata"]["migrated_from"] == "phoenix_kit_email_templates"
      assert welcome["metadata"]["email_category"] == "marketing"
      assert welcome["metadata"]["origin"] == "kept"

      # A creator that no longer exists is not carried into a real FK.
      assert Enum.find(layouts, &(&1["name"] == "digest_layout"))["created_by_user_uuid"] == nil
      # Only "active" stays active; a draft was never offered by the editor.
      promo = Enum.find(layouts, &(&1["name"] == "promo_layout"))
      assert promo["status"] == "archived"
      assert promo["metadata"]["email_status"] == "draft"

      # The source table is an archive now: untouched.
      assert rows("SELECT * FROM #{@prefix}.phoenix_kit_email_templates ORDER BY uuid") ==
               templates_before
    end

    test "system rows nothing points at stay behind", %{system: system} do
      run_migration(UpToTwo)

      copied = copied_uuids()
      assert Enum.all?(system, &(&1 not in copied))
    end

    test "a system row a broadcast uses comes along, archived, and keeps the reference",
         %{system: [test_email, magic_link]} do
      on_system = insert_broadcast("On a system email", test_email)

      run_migration(UpToTwo)

      assert Map.new(template_refs())[on_system] == test_email

      [row] =
        query_maps("""
        SELECT uuid, name, status, metadata, html_body
        FROM #{@prefix}.phoenix_kit_newsletters_layouts WHERE uuid = '#{test_email}'
        """)

      assert row["name"] == "test_email"
      assert row["status"] == "archived"
      assert row["metadata"]["email_is_system"] == true
      assert row["metadata"]["email_status"] == "active"
      assert Map.keys(row["html_body"]) |> Enum.sort() == Enum.sort(@languages)

      # The other system row has no user: not copied.
      refute magic_link in copied_uuids()
    end

    test "a system row the default setting names comes along, archived",
         %{system: [_test_email, magic_link]} do
      Repo.query!(
        "INSERT INTO #{@prefix}.phoenix_kit_settings (key, value) VALUES ($1, $2)",
        ["newsletters_default_template", magic_link]
      )

      run_migration(UpToTwo)

      assert magic_link in copied_uuids()

      assert [["archived"]] =
               rows(
                 "SELECT status FROM #{@prefix}.phoenix_kit_newsletters_layouts WHERE uuid = '#{magic_link}'"
               )
    end

    test "a schema without the settings table reads as no default set", %{operator: operator} do
      Repo.query!("DROP TABLE #{@prefix}.phoenix_kit_settings")

      run_migration(UpToTwo)

      assert Enum.sort(copied_uuids()) == Enum.sort(operator)
    end

    test "a carried-over system row is copied once, however often V2 runs",
         %{system: [test_email | _]} do
      insert_broadcast("On a system email", test_email)

      run_migration(UpToTwo)

      for _ <- 1..2 do
        @prefix |> Migrations.up_statements(2) |> Enum.each(&Repo.query!/1)
      end

      assert Enum.count(copied_uuids(), &(&1 == test_email)) == 1
    end

    test "every broadcast keeps its template_uuid, now behind the new FK",
         %{broadcasts: broadcasts} do
      before = template_refs()
      assert length(before) == 10

      run_migration(UpToTwo)

      assert template_refs() == before
      assert Enum.all?(before, fn {_b, t} -> t != nil end)
      assert length(broadcasts) == 10

      assert [fk] = template_fks(@prefix)
      assert fk.name == "fk_newsletters_broadcasts_template"
      assert fk.target == "phoenix_kit_newsletters_layouts"
      assert fk.on_delete == "n"
    end

    test "a second V2 run changes nothing" do
      run_migration(UpToTwo)
      snapshot = snapshot()

      # The up/1 path: back to 1, up to 2 again.
      run_migration(DownToOne)
      assert version(@prefix) == 1
      run_migration(UpToTwo)
      assert snapshot() == snapshot

      # The raw statements, twice more, as the test helper replays them.
      for _ <- 1..2 do
        @prefix |> Migrations.up_statements(2) |> Enum.each(&Repo.query!/1)
      end

      assert snapshot() == snapshot
    end

    test "the import runs once: later email templates never come in on a replay" do
      run_migration(UpToTwo)
      before = copied_uuids()

      # An operator template created after V2: before the one-time mark, a
      # replay imported it as an ACTIVE layout.
      late = insert_template("order_shipped", "active", false, nil)

      # A replay of the cumulative chain (what a V3 run does)…
      @prefix |> Migrations.up_statements(2) |> Enum.each(&Repo.query!/1)
      assert Enum.sort(copied_uuids()) == Enum.sort(before)

      # …and a rollback below 2 followed by up again.
      run_migration(DownToOne)
      run_migration(UpToTwo)

      refute late in copied_uuids()
      assert Enum.sort(copied_uuids()) == Enum.sort(before)

      assert [["pknl_layouts:imported"]] =
               rows(
                 "SELECT obj_description('#{@prefix}.phoenix_kit_newsletters_layouts'::regclass, 'pg_class')"
               )
    end

    test "a name already taken by another layout is copied under a suffixed name",
         %{operator: [welcome | _]} do
      create_layouts_table()
      other = uuid()
      insert_layout(other, "welcome_layout")

      run_migration(UpToTwo)

      [[name]] =
        rows(
          "SELECT name FROM #{@prefix}.phoenix_kit_newsletters_layouts WHERE uuid = '#{welcome}'"
        )

      assert name ==
               "welcome_layout_" <> (welcome |> String.replace("-", "") |> binary_part(0, 8))

      # Its broadcasts still point at it — nothing was cleared.
      assert Enum.any?(template_refs(), fn {_b, t} -> t == welcome end)
    end

    test "a row already there under its uuid is kept as it is (ON CONFLICT (uuid))",
         %{operator: [welcome | _]} do
      create_layouts_table()
      insert_layout(welcome, "kept_by_hand")

      run_migration(UpToTwo)

      assert [["kept_by_hand"]] =
               rows(
                 "SELECT name FROM #{@prefix}.phoenix_kit_newsletters_layouts WHERE uuid = '#{welcome}'"
               )

      assert Enum.count(copied_uuids(), &(&1 == welcome)) == 1
    end

    test "each cleared reference is reported as a NOTICE naming the broadcast and the uuid" do
      Repo.query!("""
      ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      DROP CONSTRAINT fk_newsletters_broadcasts_template
      """)

      gone = uuid()
      dangling = insert_broadcast("On nothing", gone)

      notices =
        @prefix
        |> Migrations.up_statements(2)
        |> Enum.flat_map(&Repo.query!(&1).messages)
        |> Enum.map(& &1.message)

      assert [notice] = Enum.filter(notices, &(&1 =~ "template_uuid cleared"))
      assert notice =~ dangling
      assert notice =~ gone
    end

    test "rolling V2 back keeps the layouts table, its rows and the new FK" do
      run_migration(UpToTwo)
      snapshot = snapshot()

      run_migration(DownToOne)

      assert version(@prefix) == 1
      assert snapshot() == snapshot
    end

    test "the old FK is found by what it is, not by its name" do
      Repo.query!("""
      ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      RENAME CONSTRAINT fk_newsletters_broadcasts_template TO fk_mailing_broadcasts_template
      """)

      assert [%{name: "fk_mailing_broadcasts_template", target: "phoenix_kit_email_templates"}] =
               template_fks(@prefix)

      run_migration(UpToTwo)

      assert [
               %{
                 name: "fk_newsletters_broadcasts_template",
                 target: "phoenix_kit_newsletters_layouts"
               }
             ] =
               template_fks(@prefix)
    end

    test "only a reference to nothing is cleared; system and operator references stay",
         %{system: [system | _], operator: [kept | _]} do
      on_system = insert_broadcast("On a system email", system)

      # The old FK would refuse a dangling uuid; a host that lost it (or never
      # had it) can still hold one.
      Repo.query!("""
      ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      DROP CONSTRAINT fk_newsletters_broadcasts_template
      """)

      dangling = insert_broadcast("On nothing", uuid())
      on_operator = insert_broadcast("On an operator layout", kept)

      run_migration(UpToTwo)

      refs = Map.new(template_refs())
      assert refs[on_system] == system
      assert refs[dangling] == nil
      assert refs[on_operator] == kept
      assert [%{target: "phoenix_kit_newsletters_layouts"}] = template_fks(@prefix)
    end

    test "deleting a layout clears the broadcasts that used it", %{operator: [layout | _]} do
      run_migration(UpToTwo)

      users = Enum.filter(template_refs(), fn {_b, t} -> t == layout end)
      assert users != []

      Repo.query!("DELETE FROM #{@prefix}.phoenix_kit_newsletters_layouts WHERE uuid = $1", [
        dump(layout)
      ])

      refs = Map.new(template_refs())
      assert Enum.all?(users, fn {b, _t} -> refs[b] == nil end)
    end

    test "a template_uuid outside the layouts table is now refused" do
      run_migration(UpToTwo)

      assert_raise Postgrex.Error, ~r/fk_newsletters_broadcasts_template/, fn ->
        insert_broadcast("Unknown layout", uuid())
      end
    end
  end

  describe "an install without the email-templates table" do
    setup do
      create_host(@bare, email_templates?: false)
      :ok
    end

    test "V2 runs from nothing: both tables, an empty layouts table, the new FK" do
      run_migration(BareUpToTwo)

      assert version(@bare) == 2

      assert count("#{@bare}.phoenix_kit_newsletters_layouts") == 0
      assert count("#{@bare}.phoenix_kit_newsletters_broadcasts") == 0

      assert [
               %{
                 name: "fk_newsletters_broadcasts_template",
                 target: "phoenix_kit_newsletters_layouts"
               }
             ] =
               template_fks(@bare)
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp create_host(prefix, email_templates?: email_templates?) do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{prefix}")
    Repo.query!("CREATE TABLE #{prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

    # Core's settings columns V2 reads (key/value).
    Repo.query!("""
    CREATE TABLE #{prefix}.phoenix_kit_settings (
      "key" character varying(255) NOT NULL,
      "value" character varying(255)
    )
    """)

    if email_templates? do
      # Core's V135 column shape for the table V2 reads.
      Repo.query!("""
      CREATE TABLE #{prefix}.phoenix_kit_email_templates (
        "uuid" uuid PRIMARY KEY,
        "name" character varying(255) NOT NULL,
        "slug" character varying(255) NOT NULL,
        "display_name" jsonb NOT NULL,
        "description" jsonb,
        "subject" jsonb NOT NULL,
        "html_body" jsonb NOT NULL,
        "text_body" jsonb NOT NULL,
        "category" character varying(255) DEFAULT 'transactional' NOT NULL,
        "status" character varying(255) DEFAULT 'draft' NOT NULL,
        "variables" jsonb DEFAULT '{}'::jsonb,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "usage_count" integer DEFAULT 0 NOT NULL,
        "last_used_at" timestamp with time zone,
        "version" integer DEFAULT 1 NOT NULL,
        "is_system" boolean DEFAULT false NOT NULL,
        "created_by_user_uuid" uuid,
        "updated_by_user_uuid" uuid,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL
      )
      """)
    end
  end

  defp insert_template(name, status, system?, created_by) do
    id = uuid()
    map = fn fun -> Map.new(@languages, &{&1, fun.(&1)}) end

    Repo.query!(
      """
      INSERT INTO #{@prefix}.phoenix_kit_email_templates
        (uuid, name, slug, display_name, subject, html_body, text_body, category, status,
         metadata, is_system, created_by_user_uuid, inserted_at, updated_at)
      VALUES ($1, $2, $2, $3, $4, $5, $6, 'marketing', $7, $8, $9, $10, now(), now())
      """,
      [
        dump(id),
        name,
        map.(&"#{name} #{&1}"),
        map.(&"{{subject}} (#{&1})"),
        map.(&html(name, &1)),
        map.(&"#{name} #{&1} {{content}}"),
        status,
        %{"origin" => "kept"},
        system?,
        created_by && dump(created_by)
      ]
    )

    id
  end

  # The layouts table as V2 builds it, before V2 runs — for a row that is
  # already there when the import happens.
  defp create_layouts_table do
    @prefix
    |> Migrations.up_statements(2)
    |> Enum.find(&(&1 =~ "CREATE TABLE IF NOT EXISTS #{@prefix}.phoenix_kit_newsletters_layouts"))
    |> Repo.query!()

    Repo.query!("CREATE UNIQUE INDEX ON #{@prefix}.phoenix_kit_newsletters_layouts (uuid)")

    Repo.query!(
      "CREATE UNIQUE INDEX idx_newsletters_layouts_name ON #{@prefix}.phoenix_kit_newsletters_layouts (name)"
    )
  end

  defp insert_layout(id, name) do
    Repo.query!(
      "INSERT INTO #{@prefix}.phoenix_kit_newsletters_layouts (uuid, name, html_body) VALUES ($1, $2, $3)",
      [dump(id), name, %{"en" => "{{{content}}}"}]
    )
  end

  defp html(name, language),
    do: ~s(<html lang="#{language}"><body><h1>#{name}</h1>{{content}}</body></html>)

  defp insert_broadcast(subject, template_uuid) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO #{@prefix}.phoenix_kit_newsletters_broadcasts (subject, template_uuid, source_type)
        VALUES ($1, $2, 'user_group') RETURNING uuid
        """,
        [subject, template_uuid && dump(template_uuid)]
      )

    load(id)
  end

  # ── readers ──────────────────────────────────────────────────────────

  defp template_refs do
    "SELECT uuid, template_uuid FROM #{@prefix}.phoenix_kit_newsletters_broadcasts ORDER BY uuid"
    |> Repo.query!()
    |> Map.fetch!(:rows)
    |> Enum.map(fn [b, t] -> {load(b), t && load(t)} end)
  end

  # Every FK on broadcasts.template_uuid, whatever its name or target.
  defp template_fks(prefix) do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conname, t.relname, c.confdeltype::text
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.confrelid
      WHERE c.conrelid = '#{prefix}.phoenix_kit_newsletters_broadcasts'::regclass
        AND c.contype = 'f'
        AND c.conkey = ARRAY[(
          SELECT attnum FROM pg_attribute
          WHERE attrelid = '#{prefix}.phoenix_kit_newsletters_broadcasts'::regclass
            AND attname = 'template_uuid'
        )]::smallint[]
      ORDER BY c.conname
      """)

    Enum.map(rows, fn [name, target, on_delete] ->
      %{name: name, target: target, on_delete: on_delete}
    end)
  end

  defp snapshot do
    %{
      layouts: rows("SELECT * FROM #{@prefix}.phoenix_kit_newsletters_layouts ORDER BY uuid"),
      broadcasts: template_refs(),
      fks: template_fks(@prefix),
      templates: rows("SELECT * FROM #{@prefix}.phoenix_kit_email_templates ORDER BY uuid"),
      constraints:
        column("""
        SELECT conname FROM pg_constraint
        WHERE conrelid = '#{@prefix}.phoenix_kit_newsletters_layouts'::regclass ORDER BY conname
        """),
      indexes:
        column("""
        SELECT indexname FROM pg_indexes
        WHERE schemaname = '#{@prefix}' AND tablename = 'phoenix_kit_newsletters_layouts'
        ORDER BY indexname
        """)
    }
  end

  defp version(prefix) do
    %{rows: [[comment]]} =
      Repo.query!(
        "SELECT obj_description('#{prefix}.phoenix_kit_newsletters_broadcasts'::regclass, 'pg_class')"
      )

    case comment do
      "pknl_schema:" <> n -> String.to_integer(n)
      _ -> 0
    end
  end

  defp query_maps(sql) do
    %{columns: columns, rows: rows} = Repo.query!(sql)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn
        {col, <<_::128>> = bin} when col in ["uuid", "created_by_user_uuid"] -> {col, load(bin)}
        pair -> pair
      end)
    end)
  end

  defp rows(sql), do: Repo.query!(sql).rows

  defp copied_uuids do
    "SELECT uuid FROM #{@prefix}.phoenix_kit_newsletters_layouts"
    |> column()
    |> Enum.map(&load/1)
  end

  defp column(sql), do: sql |> Repo.query!() |> Map.fetch!(:rows) |> Enum.map(&hd/1)

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
    n
  end

  defp uuid, do: Ecto.UUID.generate()
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp load(bin), do: Ecto.UUID.load!(bin)

  # In this process, through Ecto's own runner — see
  # migrations_data_safety_test.exs for why not Ecto.Migrator.
  defp run_migration(module) do
    Runner.run(
      Repo,
      [],
      :os.system_time(:microsecond),
      module,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )
  end
end
