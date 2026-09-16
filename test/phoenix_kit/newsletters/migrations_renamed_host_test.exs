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
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}")

    Repo.query!("""
    CREATE TABLE #{@prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)
    """)

    Repo.query!("""
    CREATE TABLE #{@prefix}.phoenix_kit_email_templates (uuid uuid PRIMARY KEY)
    """)

    # The exact current (V135-through-V158) column shape, so every guard
    # finds the columns it expects — only the PK/FK/index OBJECT NAMES are
    # the pre-rename legacy ones. `gen_random_uuid()` (pgcrypto, already
    # ensured by the main test suite's own migration bootstrap) stands in
    # for `uuid_generate_v7()` — irrelevant here, no row is ever inserted.
    Repo.query!("""
    CREATE TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts (
      "uuid" uuid DEFAULT gen_random_uuid() NOT NULL,
      "subject" character varying(998) NOT NULL,
      "markdown_body" text,
      "html_body" text,
      "text_body" text,
      "template_uuid" uuid,
      "status" character varying(20) DEFAULT 'draft'::character varying NOT NULL,
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
      "source_type" character varying(20) DEFAULT 'newsletters_list'::character varying NOT NULL,
      "crm_list_uuid" uuid,
      "source_params" jsonb DEFAULT '{}'::jsonb NOT NULL,
      "attachments" jsonb DEFAULT '[]'::jsonb NOT NULL,
      CONSTRAINT phoenix_kit_mailing_broadcasts_pkey PRIMARY KEY (uuid)
    )
    """)

    Repo.query!("""
    CREATE TABLE #{@prefix}.phoenix_kit_newsletters_deliveries (
      "uuid" uuid DEFAULT gen_random_uuid() NOT NULL,
      "broadcast_uuid" uuid NOT NULL,
      "user_uuid" uuid,
      "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
      "sent_at" timestamp with time zone,
      "delivered_at" timestamp with time zone,
      "opened_at" timestamp with time zone,
      "error" text,
      "message_id" character varying(255),
      "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
      "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
      "recipient_email" public.citext,
      "crm_contact_uuid" uuid,
      CONSTRAINT phoenix_kit_mailing_deliveries_pkey PRIMARY KEY (uuid)
    )
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT fk_mailing_broadcasts_created_by FOREIGN KEY (created_by_user_uuid)
      REFERENCES #{@prefix}.phoenix_kit_users(uuid) ON DELETE SET NULL
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT fk_mailing_broadcasts_template FOREIGN KEY (template_uuid)
      REFERENCES #{@prefix}.phoenix_kit_email_templates(uuid) ON DELETE SET NULL
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_deliveries
      ADD CONSTRAINT fk_mailing_deliveries_broadcast FOREIGN KEY (broadcast_uuid)
      REFERENCES #{@prefix}.phoenix_kit_newsletters_broadcasts(uuid) ON DELETE CASCADE
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_deliveries
      ADD CONSTRAINT fk_mailing_deliveries_user FOREIGN KEY (user_uuid)
      REFERENCES #{@prefix}.phoenix_kit_users(uuid) ON DELETE CASCADE
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_broadcasts_scheduled_at ON #{@prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_broadcasts_status ON #{@prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (status)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_deliveries_broadcast ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (broadcast_uuid)
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX idx_mailing_deliveries_message_id ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (message_id) WHERE (message_id IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_deliveries_status ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (status)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_deliveries_user ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (user_uuid)
    """)

    :ok
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

  defp index_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [@prefix, table]
      )

    Enum.map(rows, &hd/1)
  end
end
