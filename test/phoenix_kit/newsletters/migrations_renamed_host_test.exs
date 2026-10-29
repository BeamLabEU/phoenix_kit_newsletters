defmodule PhoenixKitNewsletters.MigrationsRenamedHostTest do
  use PhoenixKitNewsletters.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitNewsletters.Migrations
  alias PhoenixKitNewsletters.Test.Repo

  @moduledoc """
  Reproduces a real host shape found on `decor_3d_print`: a host-level
  migration (`20260316_rename_mailing_to_newsletters`) renamed both tables
  from `phoenix_kit_mailing_broadcasts`/`_deliveries` to their current
  `phoenix_kit_newsletters_*` names, but `ALTER TABLE ... RENAME TO` never
  renames a table's own constraints or indexes — every V135-era object on
  that host still carries its *original* `phoenix_kit_mailing_*`/
  `fk_mailing_*`/`idx_mailing_*` name (see `PhoenixKitNewsletters.Migrations`'
  moduledoc, "Guards are semantic, not name-based", for the full history).

  A name-based guard (`WHERE conname = 'phoenix_kit_newsletters_broadcasts_pkey'`)
  reads this shape as "no primary key exists" and tries to add a second one,
  which Postgres rejects outright (`multiple primary keys ... are not
  allowed`) — this is not hypothetical, it is the exact error `up/1` raised
  against the real host. The FK and index guards have the same defect in a
  quieter form: no error, just a silent, functionally duplicate object next
  to the still-present legacy one (already observed for a sibling module,
  `phoenix_kit_posts`, as 3 duplicate UNIQUE indexes on the same host).

  Everything here runs against an isolated `nlrenamed_host` prefix schema
  inside the sandboxed test transaction (Postgres DDL is transactional, so
  it rolls back with everything else at `on_exit` — no manual cleanup), with
  two minimal one-column stub tables standing in for `phoenix_kit_users`/
  `phoenix_kit_email_templates` so the real FKs have something to reference.

  Both CHECK constraints are ALSO present in the fixture, under their real
  (core) names — unlike the PK/FK/index objects, core has always created
  both CHECKs under their current `phoenix_kit_newsletters_*` name (they
  were introduced at `V152`/`V158`, after the only rename event found in
  the wild), so a renamed host never has a differently-named one. Included
  anyway so `check_guard`'s idempotence is exercised on a host that already
  has them — a name-based OR-fallback bug there would show up as a second,
  duplicate CHECK, not as an error.

  `async: false` — shares the migrator's sandbox connection, like
  `migrations_data_safety_test.exs`.
  """

  @prefix "nlrenamed_host"

  defmodule RunUpToOneRenamedHost do
    @moduledoc false
    use Ecto.Migration

    def up, do: PhoenixKitNewsletters.Migrations.up(prefix: "nlrenamed_host", version: 1)
    def down, do: :ok
  end

  setup do
    PhoenixKitNewsletters.RenamedHostFixture.create!(@prefix)
  end

  test "up/1 against a host whose V135-era objects kept their pre-rename names does not error, " <>
         "does not duplicate any object, and still stamps the marker" do
    # This is the regression itself: a name-based PK guard raises
    # "multiple primary keys for table ... are not allowed" here.
    run_migration(RunUpToOneRenamedHost)

    # The legacy PK is untouched — no second, differently-named PK exists.
    assert pkey_names("phoenix_kit_newsletters_broadcasts") == [
             "phoenix_kit_mailing_broadcasts_pkey"
           ]

    assert pkey_names("phoenix_kit_newsletters_deliveries") == [
             "phoenix_kit_mailing_deliveries_pkey"
           ]

    # The 4 legacy FKs are untouched — no duplicate, differently-named FK
    # was added alongside any of them.
    assert fk_names("phoenix_kit_newsletters_broadcasts") |> Enum.sort() ==
             Enum.sort(["fk_mailing_broadcasts_created_by", "fk_mailing_broadcasts_template"])

    assert fk_names("phoenix_kit_newsletters_deliveries") |> Enum.sort() ==
             Enum.sort(["fk_mailing_deliveries_broadcast", "fk_mailing_deliveries_user"])

    # The 6 legacy V135-era indexes are untouched, AND the genuinely-new
    # V152+ indexes (which this pre-rename fixture never had) got created
    # under this chain's own names — both must be true at once.
    assert index_names("phoenix_kit_newsletters_broadcasts") |> Enum.sort() ==
             Enum.sort([
               "phoenix_kit_mailing_broadcasts_pkey",
               "idx_mailing_broadcasts_scheduled_at",
               "idx_mailing_broadcasts_status",
               "idx_newsletters_broadcasts_crm_list"
             ])

    assert index_names("phoenix_kit_newsletters_deliveries") |> Enum.sort() ==
             Enum.sort([
               "phoenix_kit_mailing_deliveries_pkey",
               "idx_mailing_deliveries_broadcast",
               "idx_mailing_deliveries_message_id",
               "idx_mailing_deliveries_status",
               "idx_mailing_deliveries_user",
               "idx_newsletters_deliveries_crm_contact",
               "idx_newsletters_deliveries_uniq_broadcast_user",
               "idx_newsletters_deliveries_uniq_broadcast_contact",
               "idx_newsletters_deliveries_uniq_broadcast_email"
             ])

    # Both CHECKs are already present under their real (core) names — exactly
    # one of each, not a duplicate added alongside by a name-match that
    # somehow missed them.
    assert check_names("phoenix_kit_newsletters_broadcasts") == [
             "phoenix_kit_newsletters_broadcasts_attachments_is_array"
           ]

    assert check_names("phoenix_kit_newsletters_deliveries") == [
             "phoenix_kit_newsletters_deliveries_recipient_check"
           ]

    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  test "a second up/1 run against the same renamed-host shape is idempotent" do
    run_migration(RunUpToOneRenamedHost)
    run_migration(RunUpToOneRenamedHost)

    # Still exactly one PK, no duplicates anywhere, still version 1 — a
    # second run must not add a THIRD copy of anything either.
    assert pkey_names("phoenix_kit_newsletters_broadcasts") == [
             "phoenix_kit_mailing_broadcasts_pkey"
           ]

    assert fk_names("phoenix_kit_newsletters_broadcasts") |> length() == 2
    assert fk_names("phoenix_kit_newsletters_deliveries") |> length() == 2

    assert check_names("phoenix_kit_newsletters_broadcasts") |> length() == 1
    assert check_names("phoenix_kit_newsletters_deliveries") |> length() == 1

    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  # ── helpers ──────────────────────────────────────────────────────────

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

  defp pkey_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = '#{@prefix}.#{table}'::regclass AND contype = 'p'"
      )

    Enum.map(rows, &hd/1)
  end

  defp fk_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = '#{@prefix}.#{table}'::regclass AND contype = 'f'"
      )

    Enum.map(rows, &hd/1)
  end

  defp check_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = '#{@prefix}.#{table}'::regclass AND contype = 'c'"
      )

    Enum.map(rows, &hd/1)
  end

  defp index_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [@prefix, table]
      )

    Enum.map(rows, &hd/1)
  end
end
