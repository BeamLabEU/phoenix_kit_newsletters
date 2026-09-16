defmodule PhoenixKitNewsletters.MigrationsDataSafetyTest do
  use PhoenixKitNewsletters.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.{Broadcast, Delivery}
  alias PhoenixKitNewsletters.Migrations
  alias PhoenixKitNewsletters.Test.Repo

  @moduledoc """
  The acceptance a table full of real broadcasts and deliveries actually
  needs, and that no static test can give: REAL rows, a REAL `down/1` run
  as a migration, and the rows still there afterwards, byte-for-byte.

  `migrations_test.exs` proves what the chain BUILDS (no
  DROP/TRUNCATE/DELETE token anywhere, `down/1` emits marker bookkeeping
  only). That is a proof about text. This file proves what the chain DOES
  to a database that holds a real broadcast (with a non-empty
  `attachments` list) and a real CRM-shaped delivery (`recipient_email`
  set, `user_uuid` nil — exercising the recipient CHECK constraint and the
  citext column on a live row, not just a synthetic one) — on
  `phoenix_kit_newsletters_broadcasts`, the anchor table, and its
  dependent `phoenix_kit_newsletters_deliveries`.

  The last test is the mutation check: it runs the same survival harness
  against a deliberately destructive rollback and requires it to FAIL.
  Without that, a survival assertion that silently stopped asserting (wrong
  table name, empty row set) would stay green forever and prove nothing.

  `async: false` — the migrator wants the shared sandbox connection.
  """

  defmodule RollbackToZero do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 0)
    def down, do: :ok
  end

  defmodule RollbackToOneFromMap do
    @moduledoc false
    use Ecto.Migration

    # Deliberately the MAP shape: it is accepted, so it must carry
    # `:version` like the keyword list does.
    def up, do: Migrations.down(%{prefix: "public", version: 1})
    def down, do: :ok
  end

  defmodule DestructiveRollback do
    @moduledoc false
    use Ecto.Migration

    # NOT what the package ships — the mutant the survival check must catch.
    def up do
      execute("DELETE FROM public.phoenix_kit_newsletters_deliveries")
      execute("DELETE FROM public.phoenix_kit_newsletters_broadcasts")
    end

    def down, do: :ok
  end

  defmodule RunUpToOne do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(prefix: "public", version: 1)
    def down, do: :ok
  end

  setup do
    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Data safety broadcast",
        source_type: "user_group",
        source_params: %{"role_uuids" => [Ecto.UUID.generate()]},
        attachments: [Ecto.UUID.generate()]
      })

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{
        broadcast_uuid: broadcast.uuid,
        recipient_email: "reader@example.com"
      })
      |> Repo.insert()

    {:ok, broadcast: broadcast, delivery: delivery}
  end

  test "a real down(version: 0) leaves the seeded broadcast and delivery alive",
       %{broadcast: broadcast, delivery: delivery} do
    broadcast_count = count("phoenix_kit_newsletters_broadcasts")
    delivery_count = count("phoenix_kit_newsletters_deliveries")

    run_migration(RollbackToZero)

    assert count("phoenix_kit_newsletters_broadcasts") == broadcast_count,
           "rolling this chain back changed the row count in phoenix_kit_newsletters_broadcasts"

    assert count("phoenix_kit_newsletters_deliveries") == delivery_count,
           "rolling this chain back changed the row count in phoenix_kit_newsletters_deliveries"

    reloaded_broadcast = Repo.get!(Broadcast, broadcast.uuid)
    assert reloaded_broadcast.subject == broadcast.subject
    assert reloaded_broadcast.attachments == broadcast.attachments
    assert reloaded_broadcast.source_type == broadcast.source_type

    reloaded_delivery = Repo.get!(Delivery, delivery.uuid)
    assert reloaded_delivery.recipient_email == delivery.recipient_email
    assert reloaded_delivery.broadcast_uuid == delivery.broadcast_uuid
    assert reloaded_delivery.user_uuid == nil
  end

  test "the rollback still does its one real job: the marker is cleared" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    run_migration(RollbackToZero)

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "a rollback to version 1 passed as a map stops at 1, not at 0" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'")

    run_migration(RollbackToOneFromMap)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1,
           "the map shape lost :version and rolled the chain further back than asked"
  end

  test "a real up(version: 1) run is idempotent and leaves seeded rows untouched",
       %{broadcast: broadcast, delivery: delivery} do
    # up/1 re-reads the installed version, calls ensure_extension!/1 (twice
    # — pgcrypto and citext) and ensure_uuid_v7_function/1, then runs the
    # same guarded statements up_statements/2 emits — clearing the marker
    # first simulates the "database behind the target" branch up/1 checks
    # before doing anything, so this exercises that whole path for real
    # rather than as SQL text applied directly (test_helper.exs does the
    # latter, once, before any test runs — this is the only place up/1
    # itself, as a function, gets a real migration-context run).
    broadcast_count = count("phoenix_kit_newsletters_broadcasts")
    delivery_count = count("phoenix_kit_newsletters_deliveries")

    Repo.query!("COMMENT ON TABLE phoenix_kit_newsletters_broadcasts IS NULL")

    run_migration(RunUpToOne)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    assert count("phoenix_kit_newsletters_broadcasts") == broadcast_count,
           "a real up(version: 1) run changed the row count in phoenix_kit_newsletters_broadcasts"

    assert count("phoenix_kit_newsletters_deliveries") == delivery_count,
           "a real up(version: 1) run changed the row count in phoenix_kit_newsletters_deliveries"

    assert Repo.get!(Broadcast, broadcast.uuid).subject == broadcast.subject
    assert Repo.get!(Delivery, delivery.uuid).recipient_email == delivery.recipient_email

    # Idempotence: every table/pkey/check/index/fk statement is
    # CREATE-IF-NOT-EXISTS/DO-guarded against objects that already exist
    # (core's baseline created them), so running up/1 again must be a no-op,
    # not an error.
    run_migration(RunUpToOne)
    assert Migrations.migrated_version_runtime(prefix: "public") == 1
  end

  test "the survival check has teeth: a destructive rollback fails it", %{broadcast: broadcast} do
    broadcast_count = count("phoenix_kit_newsletters_broadcasts")

    run_migration(DestructiveRollback)

    # The same assertions the real test makes. Both must fail here, or the
    # real test above is decoration.
    assert_raise ExUnit.AssertionError, fn ->
      assert count("phoenix_kit_newsletters_broadcasts") == broadcast_count
    end

    assert_raise Ecto.NoResultsError, fn ->
      Repo.get!(Broadcast, broadcast.uuid)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Runs the migration IN THIS PROCESS, through Ecto's own migration runner,
  # rather than `Ecto.Migrator.up/4`. The Migrator runs the migration inside a
  # `Task`, which then has to check out the sandbox connection this test
  # already owns — it never gets it, and every assertion below dies in the
  # checkout queue instead of testing the rollback. The runner is what the
  # Migrator itself calls once it has dealt with locking and version
  # bookkeeping; going straight to it keeps the real migration context (so
  # `execute/1` inside `down/1` is the real `execute/1`) and drops only the
  # parts this file is not about.
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

  defp count(table) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}")
    count
  end
end
