defmodule PhoenixKitNewsletters.MigrationsExpressionIndexTest do
  use PhoenixKitNewsletters.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitNewsletters.Migrations
  alias PhoenixKitNewsletters.Test.Repo

  @moduledoc """
  Regression test for a real bug found by independent review of the
  semantic index guard (`PhoenixKitNewsletters.Migrations`' `index_guard/6`):
  a pre-existing EXPRESSION index sharing one column name with a plain
  index this chain wants to adopt could be misread as "the plain index
  already exists", silently skipping its creation.

  `pg_index.indkey` stores `0` — not a real attnum — for an expression
  column (e.g. the `lower(error)` half of `ON t (status, lower(error))`).
  `pg_attribute` has no row for attnum `0`, so a naive
  `JOIN pg_attribute ON attnum = k.attnum` silently DROPS that array
  position instead of erroring, shortening a 2-column expression index's
  resolved column list down to `{status}` — indistinguishable, by that
  aggregate alone, from the real, unrelated, single-column
  `idx_newsletters_deliveries_status`. Verified directly against a live
  catalog before fixing: `CREATE INDEX ON t (status, lower(error))`
  produces exactly that shortened `{status}` aggregate, with
  `indexprs IS NOT NULL` and `array_length(indkey, 1) = 2` — both of which
  the fixed guard now checks explicitly, so this exact index cannot satisfy
  it.

  `async: false` — shares the migrator's sandbox connection, like the
  other migration test files that run a real `up/1`.
  """

  @prefix "nlexpr_host"

  defmodule RunUpToOneExpressionIndexHost do
    @moduledoc false
    use Ecto.Migration

    def up, do: PhoenixKitNewsletters.Migrations.up(prefix: "nlexpr_host", version: 1)
    def down, do: :ok
  end

  setup do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)")
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit_email_templates (uuid uuid PRIMARY KEY)")

    # Full current shape, correct (core) object names throughout, EXCEPT
    # `idx_newsletters_deliveries_status` is deliberately left OUT — its
    # absence is the point: the only index touching `status` on this table
    # is the unrelated expression index added below, so this reproduces
    # "the real plain index is genuinely missing, but something else on
    # the table happens to share its first column".
    Repo.query!("""
    CREATE TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts (
      "uuid" uuid DEFAULT gen_random_uuid() NOT NULL,
      "subject" character varying(998) NOT NULL,
      "markdown_body" text, "html_body" text, "text_body" text,
      "template_uuid" uuid,
      "status" character varying(20) DEFAULT 'draft'::character varying NOT NULL,
      "scheduled_at" timestamp with time zone, "sent_at" timestamp with time zone,
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
      CONSTRAINT phoenix_kit_newsletters_broadcasts_pkey PRIMARY KEY (uuid)
    )
    """)

    Repo.query!("""
    CREATE TABLE #{@prefix}.phoenix_kit_newsletters_deliveries (
      "uuid" uuid DEFAULT gen_random_uuid() NOT NULL,
      "broadcast_uuid" uuid NOT NULL, "user_uuid" uuid,
      "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
      "sent_at" timestamp with time zone, "delivered_at" timestamp with time zone,
      "opened_at" timestamp with time zone, "error" text,
      "message_id" character varying(255),
      "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
      "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
      "recipient_email" public.citext, "crm_contact_uuid" uuid,
      CONSTRAINT phoenix_kit_newsletters_deliveries_pkey PRIMARY KEY (uuid)
    )
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT fk_newsletters_broadcasts_created_by FOREIGN KEY (created_by_user_uuid)
      REFERENCES #{@prefix}.phoenix_kit_users(uuid) ON DELETE SET NULL
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT fk_newsletters_broadcasts_template FOREIGN KEY (template_uuid)
      REFERENCES #{@prefix}.phoenix_kit_email_templates(uuid) ON DELETE SET NULL
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_deliveries
      ADD CONSTRAINT fk_newsletters_deliveries_broadcast FOREIGN KEY (broadcast_uuid)
      REFERENCES #{@prefix}.phoenix_kit_newsletters_broadcasts(uuid) ON DELETE CASCADE
    """)

    Repo.query!("""
    ALTER TABLE #{@prefix}.phoenix_kit_newsletters_deliveries
      ADD CONSTRAINT fk_newsletters_deliveries_user FOREIGN KEY (user_uuid)
      REFERENCES #{@prefix}.phoenix_kit_users(uuid) ON DELETE CASCADE
    """)

    # Every OTHER real index present under its real name...
    Repo.query!("""
    CREATE INDEX idx_newsletters_broadcasts_scheduled_at ON #{@prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_newsletters_broadcasts_crm_list ON #{@prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (crm_list_uuid) WHERE (crm_list_uuid IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_newsletters_deliveries_broadcast ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (broadcast_uuid)
    """)

    Repo.query!("""
    CREATE INDEX idx_newsletters_deliveries_user ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (user_uuid)
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX idx_newsletters_deliveries_message_id ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (message_id) WHERE (message_id IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_newsletters_deliveries_crm_contact ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (crm_contact_uuid)
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX idx_newsletters_deliveries_uniq_broadcast_user ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (broadcast_uuid, user_uuid) WHERE (user_uuid IS NOT NULL)
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX idx_newsletters_deliveries_uniq_broadcast_contact ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (broadcast_uuid, crm_contact_uuid) WHERE (crm_contact_uuid IS NOT NULL)
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX idx_newsletters_deliveries_uniq_broadcast_email ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (broadcast_uuid, recipient_email) WHERE (recipient_email IS NOT NULL)
    """)

    # ...except `idx_newsletters_broadcasts_status` and
    # `idx_newsletters_deliveries_status`, both replaced by an unrelated
    # third-party-tool-style EXPRESSION index that happens to touch the
    # same first column. Neither exists yet.
    Repo.query!("""
    CREATE INDEX some_other_tools_expression_index ON #{@prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (status, lower(subject))
    """)

    Repo.query!("""
    CREATE INDEX another_expression_index ON #{@prefix}.phoenix_kit_newsletters_deliveries
      USING btree (status, lower(error))
    """)

    :ok
  end

  test "up/1 creates the real plain status indexes even when an unrelated expression " <>
         "index on the same table shares the first column name" do
    run_migration(RunUpToOneExpressionIndexHost)

    # The regression: BEFORE the fix, the guard's column-aggregate silently
    # dropped the expression index's second (expression) key down to just
    # `{status}`, matched it against the expected `ARRAY['status']`, and
    # concluded the real plain index already existed — skipping its
    # creation entirely. Assert it actually got created.
    assert index_exists?(
             "phoenix_kit_newsletters_broadcasts",
             "idx_newsletters_broadcasts_status"
           )

    assert index_exists?(
             "phoenix_kit_newsletters_deliveries",
             "idx_newsletters_deliveries_status"
           )

    # The pre-existing expression indexes are untouched — this chain never
    # drops anything, adoption or not.
    assert index_exists?(
             "phoenix_kit_newsletters_broadcasts",
             "some_other_tools_expression_index"
           )

    assert index_exists?("phoenix_kit_newsletters_deliveries", "another_expression_index")

    # Both indexes coexist distinctly — 2 indexes touching `status` on each
    # table, not 1 (which would mean the real one never got created) and
    # not 3 (which would mean something got duplicated).
    assert status_touching_index_count("phoenix_kit_newsletters_broadcasts") == 2
    assert status_touching_index_count("phoenix_kit_newsletters_deliveries") == 2

    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  test "a second up/1 run stays idempotent with the expression index still present" do
    run_migration(RunUpToOneExpressionIndexHost)
    run_migration(RunUpToOneExpressionIndexHost)

    assert status_touching_index_count("phoenix_kit_newsletters_broadcasts") == 2
    assert status_touching_index_count("phoenix_kit_newsletters_deliveries") == 2
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

  defp index_exists?(table, name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND tablename = $2 AND indexname = $3",
        [@prefix, table, name]
      )

    rows != []
  end

  defp status_touching_index_count(table) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_indexes
        WHERE schemaname = $1 AND tablename = $2 AND indexdef ILIKE '%(status%'
        """,
        [@prefix, table]
      )

    count
  end
end
