defmodule PhoenixKitNewsletters.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitNewsletters.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_newsletters`: this package
  owns both `phoenix_kit_newsletters_broadcasts`/`phoenix_kit_newsletters_deliveries`
  tables' FUTURE shape through its module migration chain, while core's
  V135-through-V158 baseline still creates both tables on every install,
  and the chain's V1 merely ADOPTS that shape (stamps the `pknl_schema:`
  marker on the anchor table, `phoenix_kit_newsletters_broadcasts`, changes
  no shape at all — see `PhoenixKitNewsletters.Migrations`' moduledoc).

  Every test here is a pure data/string assertion over
  `up_statements/2`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.
  """

  @newsletters_tables ~w(
    phoenix_kit_newsletters_broadcasts
    phoenix_kit_newsletters_deliveries
  )

  test "PhoenixKit.Newsletters declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(PhoenixKit.Newsletters)

    assert PhoenixKit.Newsletters.migration_module() == Migrations,
           """
           PhoenixKit.Newsletters no longer declares its migration chain \
           (migration_module/0 returned #{inspect(PhoenixKit.Newsletters.migration_module())}).

           The chain is how phoenix_kit_newsletters' future shape is versioned
           (pknl_schema marker) and how `mix phoenix_kit.update` migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    alias PhoenixKit.Migrations.Postgres.Helpers

    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 1
      assert Migrations.version_table() == "phoenix_kit_newsletters_broadcasts"
    end

    test "initial_version/0" do
      assert Migrations.initial_version() == 1
    end

    # `mix phoenix_kit_hello_world.audit_migrations` (the canonical auditor
    # for this protocol) refuses to drive a coordinator missing any of these
    # five — `mix phoenix_kit.update` itself only calls
    # `migrated_version_runtime/1` + `current_version/0`, but `up/1` needs
    # `migrated_version/1` to re-read the version it is about to change.
    test "exports the full five-function protocol, plus version_table/0 and initial_version/0" do
      for {fun, arity} <- [
            {:current_version, 0},
            {:up, 1},
            {:down, 1},
            {:migrated_version, 1},
            {:migrated_version_runtime, 1},
            {:version_table, 0},
            {:initial_version, 0}
          ] do
        assert function_exported?(Migrations, fun, arity),
               "#{inspect(Migrations)} does not export #{fun}/#{arity}"
      end
    end

    # The marker decides whether any LATER version ever runs: core's
    # `classify/2` reads it and answers `:up_to_date` for every version at or
    # below it. Stamping a version this chain does not have therefore skips
    # V2 and everything after it, silently and permanently.
    test "refuses to stamp a version this chain does not have" do
      too_high = Migrations.current_version() + 1

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.up_statements("public", too_high)
      end

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.down_statements("public", too_high)
      end

      # The ceiling itself stays reachable, or the guard would just break
      # the chain instead of bounding it.
      assert Migrations.up_statements("public", Migrations.current_version()) != []
    end

    # This chain interpolates the prefix into every object it creates, and
    # Postgres TRUNCATES an identifier past 63 bytes silently rather than
    # rejecting it — so a prefix core would refuse yields object names that
    # differ from core's while every command still exits 0, breaking the
    # contract adoption rests on. The rules are therefore core's, and this
    # test compares against core rather than restating them.
    test "every public builder that emits SQL validates its own prefix" do
      for fun <- [:up_statements, :down_statements] do
        assert_raise ArgumentError, fn -> apply(Migrations, fun, ["EVIL\";DROP"]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [String.duplicate("a", 30)]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [123]) end
      end
    end

    test "the prefix rules are core's, case and length included" do
      for prefix <- [
            "public",
            "newsletters_alt",
            "Newsletters",
            "9leading_digit",
            "has-dash",
            String.duplicate("a", 20),
            String.duplicate("a", 21),
            String.duplicate("a", 30)
          ] do
        core_accepts =
          try do
            Helpers.validate_prefix!(prefix)
            true
          rescue
            ArgumentError -> false
          end

        ours_accepts =
          try do
            Migrations.up_statements(prefix)
            true
          rescue
            ArgumentError -> false
          end

        assert ours_accepts == core_accepts,
               "prefix #{inspect(prefix)}: core #{if core_accepts, do: "accepts", else: "rejects"}, " <>
                 "this chain #{if ours_accepts, do: "accepts", else: "rejects"} — the two must agree, " <>
                 "or the object names this chain creates stop matching core's"
      end
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain's per-version statement content is pinned (drift guard)" do
    # V1 is a PUBLISHED version once this ships. A host that has already run
    # it will never run it again, so editing its content does not "fix" that
    # host — it silently splits fresh installs from existing ones. Pinning
    # the exact normalised text makes that split a deliberate, visible diff
    # instead of an accidental one buried in a refactor.
    defp normalised(statements),
      do: Enum.map(statements, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

    test "V1's published statements are frozen" do
      v1 = Migrations.up_statements("public", 1) |> normalised()

      assert v1 == [
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_newsletters_broadcasts ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"subject\" character varying(998) NOT NULL, \"markdown_body\" text, \"html_body\" text, \"text_body\" text, \"template_uuid\" uuid, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"scheduled_at\" timestamp with time zone, \"sent_at\" timestamp with time zone, \"total_recipients\" integer DEFAULT 0 NOT NULL, \"sent_count\" integer DEFAULT 0 NOT NULL, \"delivered_count\" integer DEFAULT 0 NOT NULL, \"opened_count\" integer DEFAULT 0 NOT NULL, \"bounced_count\" integer DEFAULT 0 NOT NULL, \"created_by_user_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"send_profile_uuid\" uuid, \"source_type\" character varying(20) DEFAULT 'newsletters_list'::character varying NOT NULL, \"crm_list_uuid\" uuid, \"source_params\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"attachments\" jsonb DEFAULT '[]'::jsonb NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_newsletters_deliveries ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"broadcast_uuid\" uuid NOT NULL, \"user_uuid\" uuid, \"status\" character varying(20) DEFAULT 'pending'::character varying NOT NULL, \"sent_at\" timestamp with time zone, \"delivered_at\" timestamp with time zone, \"opened_at\" timestamp with time zone, \"error\" text, \"message_id\" character varying(255), \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"recipient_email\" public.citext, \"crm_contact_uuid\" uuid )",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_newsletters_broadcasts ADD CONSTRAINT phoenix_kit_newsletters_broadcasts_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_newsletters_deliveries ADD CONSTRAINT phoenix_kit_newsletters_deliveries_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND contype = 'c' AND (conname = 'phoenix_kit_newsletters_broadcasts_attachments_is_array' OR pg_get_constraintdef(oid) = 'CHECK ((jsonb_typeof(attachments) = ''array''::text))') ) THEN ALTER TABLE public.phoenix_kit_newsletters_broadcasts ADD CONSTRAINT phoenix_kit_newsletters_broadcasts_attachments_is_array CHECK (jsonb_typeof(attachments) = 'array'); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND contype = 'c' AND (conname = 'phoenix_kit_newsletters_deliveries_recipient_check' OR pg_get_constraintdef(oid) = 'CHECK ((((user_uuid IS NOT NULL) OR (recipient_email IS NOT NULL)) AND (NOT ((user_uuid IS NOT NULL) AND (crm_contact_uuid IS NOT NULL)))))') ) THEN ALTER TABLE public.phoenix_kit_newsletters_deliveries ADD CONSTRAINT phoenix_kit_newsletters_deliveries_recipient_check CHECK ((user_uuid IS NOT NULL OR recipient_email IS NOT NULL) AND NOT (user_uuid IS NOT NULL AND crm_contact_uuid IS NOT NULL)); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indpred IS NULL AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['status']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_status ON public.phoenix_kit_newsletters_broadcasts USING btree (status)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND pg_get_expr(i.indpred, i.indrelid) = '(scheduled_at IS NOT NULL)' AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['scheduled_at']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_scheduled_at ON public.phoenix_kit_newsletters_broadcasts USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND pg_get_expr(i.indpred, i.indrelid) = '(crm_list_uuid IS NOT NULL)' AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['crm_list_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_crm_list ON public.phoenix_kit_newsletters_broadcasts USING btree (crm_list_uuid) WHERE (crm_list_uuid IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indpred IS NULL AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['broadcast_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_broadcast ON public.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indpred IS NULL AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['user_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_user ON public.phoenix_kit_newsletters_deliveries USING btree (user_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = true AND am.amname = 'btree' AND pg_get_expr(i.indpred, i.indrelid) = '(message_id IS NOT NULL)' AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['message_id']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_message_id ON public.phoenix_kit_newsletters_deliveries USING btree (message_id) WHERE (message_id IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indpred IS NULL AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['status']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_status ON public.phoenix_kit_newsletters_deliveries USING btree (status)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indpred IS NULL AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['crm_contact_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_crm_contact ON public.phoenix_kit_newsletters_deliveries USING btree (crm_contact_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = true AND am.amname = 'btree' AND pg_get_expr(i.indpred, i.indrelid) = '(user_uuid IS NOT NULL)' AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['broadcast_uuid', 'user_uuid']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_uniq_broadcast_user ON public.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid, user_uuid) WHERE (user_uuid IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = true AND am.amname = 'btree' AND pg_get_expr(i.indpred, i.indrelid) = '(crm_contact_uuid IS NOT NULL)' AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['broadcast_uuid', 'crm_contact_uuid']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_uniq_broadcast_contact ON public.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid, crm_contact_uuid) WHERE (crm_contact_uuid IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND i.indisunique = true AND am.amname = 'btree' AND pg_get_expr(i.indpred, i.indrelid) = '(recipient_email IS NOT NULL)' AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['broadcast_uuid', 'recipient_email']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_uniq_broadcast_email ON public.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid, recipient_email) WHERE (recipient_email IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_users'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND attname = 'created_by_user_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_newsletters_broadcasts ADD CONSTRAINT fk_newsletters_broadcasts_created_by FOREIGN KEY (created_by_user_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_email_templates'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND attname = 'template_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_newsletters_broadcasts ADD CONSTRAINT fk_newsletters_broadcasts_template FOREIGN KEY (template_uuid) REFERENCES public.phoenix_kit_email_templates(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_newsletters_broadcasts'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND attname = 'broadcast_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_newsletters_deliveries ADD CONSTRAINT fk_newsletters_deliveries_broadcast FOREIGN KEY (broadcast_uuid) REFERENCES public.phoenix_kit_newsletters_broadcasts(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_users'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_newsletters_deliveries'::regclass AND attname = 'user_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_newsletters_deliveries ADD CONSTRAINT fk_newsletters_deliveries_user FOREIGN KEY (user_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE CASCADE; END IF; END $$",
               "COMMENT ON TABLE public.phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'"
             ]
    end
  end

  describe "the chain DDL adopts core's V135-through-V158 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_newsletters_broadcasts_pkey",
            "phoenix_kit_newsletters_deliveries_pkey",
            "phoenix_kit_newsletters_broadcasts_attachments_is_array",
            "phoenix_kit_newsletters_deliveries_recipient_check",
            "idx_newsletters_broadcasts_status",
            "idx_newsletters_broadcasts_scheduled_at",
            "idx_newsletters_broadcasts_crm_list",
            "idx_newsletters_deliveries_broadcast",
            "idx_newsletters_deliveries_user",
            "idx_newsletters_deliveries_message_id",
            "idx_newsletters_deliveries_status",
            "idx_newsletters_deliveries_crm_contact",
            "idx_newsletters_deliveries_uniq_broadcast_user",
            "idx_newsletters_deliveries_uniq_broadcast_contact",
            "idx_newsletters_deliveries_uniq_broadcast_email",
            "fk_newsletters_broadcasts_created_by",
            "fk_newsletters_broadcasts_template",
            "fk_newsletters_deliveries_broadcast",
            "fk_newsletters_deliveries_user"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V135-through-V158"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "applying up to version 0 is not an operation" do
      assert Migrations.up_statements("public", 0) == []
      assert Migrations.up_statements("newsletters_alt", 0) == []
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V135-through-V158 already created
      # everything, so every statement must be a no-op against an object
      # that is already there. One exemption: the marker COMMENT — not a
      # guarded operation, it's the thing being stamped. Unlike
      # customer_support's chain, there is no safety-net ALTER exemption
      # here — see the moduledoc for why this adoption needs none.
      exempt = ["COMMENT ON TABLE public.phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'"]

      ddl = Enum.reject(Migrations.up_statements(), &(&1 in exempt))

      for stmt <- ddl do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end

    # No `ALTER TABLE` phase at all in this chain (see the moduledoc's
    # explicit "no safety net" reasoning) — unlike both cited sibling
    # examples, whose section orders include one. Every guard (pkey, check,
    # index, fk) is wrapped in its own `DO $$ ... $$` block (see the
    # moduledoc's "Guards are semantic, not name-based"), so classification
    # looks at what EACH block does, not just that it is a `DO` block —
    # otherwise pkeys/checks/indexes/fks would all collapse into one
    # indistinguishable bucket and this test could not tell them apart.
    test "statement sections appear in the order tables -> pkeys -> checks -> indexes -> fks -> marker" do
      statements = Migrations.up_statements()

      sections =
        Enum.map(statements, fn stmt ->
          cond do
            String.starts_with?(stmt, "CREATE TABLE") -> :table
            String.starts_with?(stmt, "COMMENT ON TABLE") -> :marker
            stmt =~ "PRIMARY KEY" -> :pkey
            stmt =~ "ADD CONSTRAINT" and stmt =~ " CHECK (" -> :check
            stmt =~ "EXECUTE 'CREATE" -> :index
            stmt =~ "FOREIGN KEY" -> :fk
          end
        end)

      order = Enum.dedup(sections)

      assert order == [:table, :pkey, :check, :index, :fk, :marker],
             "sections are out of order: #{inspect(order)}"
    end
  end

  describe "the retired list_uuid model never reappears" do
    # Core's V156 dropped `list_uuid`, its FK and its index outright once
    # this module moved onto CRM lists / core roles. A naive read of core's
    # V135 CREATE TABLE text could tempt a future edit into "restoring" the
    # column for a fresh-install path — pin the negative directly, for
    # every prefix/target, so that never happens silently.
    test "up_statements/2 never emits list_uuid, its FK, or its index" do
      for prefix <- ["public", "newsletters_alt"] do
        for target <- [0, 1] do
          statements = Enum.join(Migrations.up_statements(prefix, target), "\n")

          # The quoted column form, not a bare substring scan — "list_uuid"
          # is itself a substring of the still-valid "crm_list_uuid" column,
          # so a plain `=~ "list_uuid"` check would false-positive on that.
          refute statements =~ "\"list_uuid\"",
                 "up_statements(#{inspect(prefix)}, #{target}) reintroduces list_uuid — " <>
                   "core's V156 dropped it; see the moduledoc before adding it back"

          refute statements =~ "fk_newsletters_broadcasts_list ",
                 "up_statements(#{inspect(prefix)}, #{target}) reintroduces the retired list FK"

          refute statements =~ "idx_newsletters_broadcasts_list ",
                 "up_statements(#{inspect(prefix)}, #{target}) reintroduces the retired list index"
        end
      end
    end
  end

  describe "the chain can never destroy either table" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_newsletters_broadcasts IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'"]

      assert Migrations.down_statements("newsletters_alt", 0) ==
               ["COMMENT ON TABLE newsletters_alt.phoenix_kit_newsletters_broadcasts IS NULL"]

      assert Migrations.down_statements("newsletters_alt", 1) ==
               [
                 "COMMENT ON TABLE newsletters_alt.phoenix_kit_newsletters_broadcasts IS 'pknl_schema:1'"
               ]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_newsletters_broadcasts"},
      {"CREATE TABLE", "phoenix_kit_newsletters_deliveries"},
      {"DO", "phoenix_kit_newsletters_broadcasts_pkey"},
      {"DO", "phoenix_kit_newsletters_deliveries_pkey"},
      {"DO", "phoenix_kit_newsletters_broadcasts_attachments_is_array"},
      {"DO", "phoenix_kit_newsletters_deliveries_recipient_check"},
      {"CREATE INDEX", "idx_newsletters_broadcasts_status"},
      {"CREATE INDEX", "idx_newsletters_broadcasts_scheduled_at"},
      {"CREATE INDEX", "idx_newsletters_broadcasts_crm_list"},
      {"CREATE INDEX", "idx_newsletters_deliveries_broadcast"},
      {"CREATE INDEX", "idx_newsletters_deliveries_user"},
      {"CREATE UNIQUE INDEX", "idx_newsletters_deliveries_message_id"},
      {"CREATE INDEX", "idx_newsletters_deliveries_status"},
      {"CREATE INDEX", "idx_newsletters_deliveries_crm_contact"},
      {"CREATE UNIQUE INDEX", "idx_newsletters_deliveries_uniq_broadcast_user"},
      {"CREATE UNIQUE INDEX", "idx_newsletters_deliveries_uniq_broadcast_contact"},
      {"CREATE UNIQUE INDEX", "idx_newsletters_deliveries_uniq_broadcast_email"},
      {"DO", "fk_newsletters_broadcasts_created_by"},
      {"DO", "fk_newsletters_broadcasts_template"},
      {"DO", "fk_newsletters_deliveries_broadcast"},
      {"DO", "fk_newsletters_deliveries_user"},
      {"COMMENT ON TABLE", "phoenix_kit_newsletters_broadcasts"}
    ]

    test "up_statements/2 emits exactly these operations and no others" do
      for prefix <- ["public", "newsletters_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    # Core's manifest for the 2 newsletters tables' index/constraint
    # objects, not a hand-typed list — a hand-typed list is maintained by
    # the same hand that adds a statement, so it catches a slip but never a
    # deliberate one; the manifest is written on core's side, so this
    # fails both when the chain emits an object core does not declare AND
    # when core declares an object the chain stopped adopting. The check
    # constraints and the pkeys are `class: :constraint` in the manifest
    # too, so they are picked up by the same filter as the FKs — no
    # separate handling needed.
    test "up_statements/2 emits exactly the index/constraint operations core's manifest declares for the 2 newsletters tables" do
      for prefix <- ["public", "newsletters_alt"] do
        actual =
          Migrations.up_statements(prefix, 1)
          |> Enum.reject(
            &(String.starts_with?(&1, "CREATE TABLE") or
                String.starts_with?(&1, "COMMENT ON TABLE"))
          )
          |> Enum.map(&operation/1)

        expected = expected_index_constraint_operations()

        assert Enum.sort(actual) == Enum.sort(expected),
               """
               up_statements(#{inspect(prefix)}, 1) does not emit the operation set
               core's ExpectedSchema declares for the 2 newsletters tables' indexes
               and constraints.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(expected))}
               missing:    #{inspect(Enum.sort(expected) -- Enum.sort(actual))}
               """
      end
    end

    test "the 4 real unique indexes are present, and only them" do
      unique_indexes =
        Migrations.up_statements()
        |> Enum.map(&operation/1)
        |> Enum.filter(&(elem(&1, 0) == "CREATE UNIQUE INDEX"))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort()

      assert unique_indexes == [
               "idx_newsletters_deliveries_message_id",
               "idx_newsletters_deliveries_uniq_broadcast_contact",
               "idx_newsletters_deliveries_uniq_broadcast_email",
               "idx_newsletters_deliveries_uniq_broadcast_user"
             ]
    end

    defp expected_index_constraint_operations do
      newsletters_tables = @newsletters_tables

      ExpectedSchema.objects("public")
      |> Enum.filter(fn object ->
        case object.check do
          {_kind, %{table: table}} ->
            table in newsletters_tables and object.class in [:index, :constraint] and
              Map.get(object, :presence) == :required

          _ ->
            false
        end
      end)
      |> Enum.map(fn object ->
        name = object.check |> elem(1) |> Map.fetch!(:name)

        case object.class do
          :constraint -> {"DO", name}
          :index -> {index_verb(object.create), name}
        end
      end)
    end

    defp index_verb(create) do
      if String.starts_with?(create, "CREATE UNIQUE INDEX"),
        do: "CREATE UNIQUE INDEX",
        else: "CREATE INDEX"
    end

    # `ON DELETE ...` is part of the foreign key's DEFINITION — the word
    # DELETE there describes what Postgres does to a child row when the
    # PARENT is deleted, and adoption reproducing core's FK means
    # reproducing core's referential action verbatim. Scanning the raw text
    # for the token would flag it, so the clause is removed before the scan.
    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      mutant =
        "ALTER TABLE public.phoenix_kit_newsletters_deliveries ADD CONSTRAINT x FOREIGN KEY (broadcast_uuid) " <>
          "REFERENCES public.phoenix_kit_newsletters_broadcasts(uuid) ON DELETE CASCADE; DROP TABLE public.phoenix_kit_newsletters_deliveries"

      assert strip_referential_actions(mutant) =~ forbidden

      assert strip_referential_actions("DELETE FROM public.phoenix_kit_newsletters_broadcasts") =~
               forbidden

      assert strip_referential_actions("TRUNCATE public.phoenix_kit_newsletters_broadcasts") =~
               forbidden
    end

    test "no statement anywhere in the data-level chain can drop a table, truncate, or delete rows" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "newsletters_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute strip_referential_actions(stmt) =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. A pkey/check/fk DO block is
    # identified by the constraint it adds; an index DO block (guarded via
    # `EXECUTE` — see the moduledoc's "Guards are semantic, not name-based")
    # is identified by the `CREATE [UNIQUE] INDEX` text inside its own
    # `EXECUTE '...'` argument, since the DO block's own verb says nothing
    # about either kind of target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      cond do
        String.starts_with?(normalized, "DO ") and
            normalized =~ ~r/EXECUTE '(CREATE|CREATE UNIQUE)/ ->
          [_, verb, name] =
            Regex.run(
              ~r/EXECUTE '(CREATE UNIQUE INDEX|CREATE INDEX) IF NOT EXISTS (\w+)/,
              normalized
            )

          {verb, name}

        String.starts_with?(normalized, "DO ") ->
          [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
          {"DO", constraint}

        true ->
          [_, verb, object] =
            Regex.run(
              ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
              normalized
            )

          {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/2` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1` would
    # have passed every one of them — the guard was watching the data while
    # the function did the work.
    @source "lib/phoenix_kit/newsletters/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every DDL statement this chain runs via execute/1 must come from
             up_statements/2 or down_statements/2, because those are what the
             tests above compare against their expected content. A statement
             executed directly (rather than piped in via &execute/1) is
             invisible to all of them. (up/1's own ensure_extension!/1 and
             ensure_uuid_v7_function/1 calls are unaffected by this check —
             they run their own idempotent setup outside of execute/1
             entirely, and are exercised for real by
             migrations_data_safety_test.exs instead.)
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops a table" in prose, which
    # a whole-file, case-insensitive scan would flag as a false positive on
    # the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the tables)" do
    alias PhoenixKit.Migrations.ExpectedSchema
    alias PhoenixKit.Newsletters.Broadcast
    alias PhoenixKit.Newsletters.Delivery

    @width_schemas %{
      "phoenix_kit_newsletters_broadcasts" => Broadcast,
      "phoenix_kit_newsletters_deliveries" => Delivery
    }

    # The lesson phoenix_kit_legal paid for once (three disagreeing DDLs of
    # one table): never a second copy of a width. Parsed back out of each
    # CREATE rather than trusted, so a hard-coded number slipped into
    # up_statements/2 instead of a schema's column_widths/0 fails here even
    # though the two happen to agree today.
    test "every varchar width in each CREATE is that table's schema's column_widths/0" do
      statements = Migrations.up_statements("public", 1)

      for {table, schema} <- @width_schemas do
        columns = v1_columns(statements, table)

        parsed =
          columns
          |> Enum.filter(fn {_col, %{type: type}} -> type =~ "character varying" end)
          |> Map.new(fn {col, %{type: type}} ->
            [_, width] = Regex.run(~r/character varying\((\d+)\)/, type)
            {String.to_existing_atom(col), String.to_integer(width)}
          end)

        assert parsed == schema.column_widths(),
               """
               #{table}: the CREATE widths and #{inspect(schema)}.column_widths/0 disagree.

               parsed from DDL: #{inspect(parsed)}
               declared:        #{inspect(schema.column_widths())}
               """
      end
    end

    # Core's V135-through-V158 baseline still creates these tables and
    # core's ExpectedSchema audits that shape, so until the first
    # shape-changing chain version the two DDLs must agree — with NO
    # documented exception (unlike customer_support's `changed_by_uuid`):
    # core's source, core's manifest, and this chain's V1 all agree
    # byte-for-byte today (see the moduledoc's "Ownership situation").
    test "every column core declares matches V1's, in full, for every table" do
      statements = Migrations.up_statements("public", 1)

      for table <- @newsletters_tables do
        core = core_columns(table)
        ours = v1_columns(statements, table)

        assert Map.keys(ours) -- Map.keys(core) == [],
               "#{table}: V1 creates columns core's manifest does not declare: " <>
                 inspect(Map.keys(ours) -- Map.keys(core))

        assert Map.keys(core) -- Map.keys(ours) == [],
               "#{table}: V1 does not create columns core's manifest declares: " <>
                 inspect(Map.keys(core) -- Map.keys(ours))

        for {column, expected} <- core do
          assert Map.fetch!(ours, column) == expected,
                 """
                 #{table}.#{column}: V1 and core's manifest disagree on the column's shape.

                 V1:              #{inspect(Map.fetch!(ours, column))}
                 core's manifest: #{inspect(expected)}

                 V1 is an adoption and must be shape-identical to core's
                 baseline. A deliberate change is a chain version (V2+).
                 """
        end
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision —
    # e.g. deliveries.user_uuid's NOT NULL was dropped by V152, so its
    # newest revision (not the V135 original) is what V1 must match.
    defp core_columns(table) do
      prefix = "column:#{table}."

      ExpectedSchema.objects("public")
      |> Enum.filter(&(&1.class == :column and String.starts_with?(&1.id, prefix)))
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, prefix, ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits for
    # `table`.
    defp v1_columns(statements, table) do
      create = table_create(statements, table)

      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp table_create(statements, table) do
      Enum.find(
        statements,
        &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
      )
    end

    defp parse_column(definition) do
      {definition, not_null} =
        case String.replace_suffix(definition, " NOT NULL", "") do
          ^definition -> {definition, false}
          trimmed -> {trimmed, true}
        end

      case String.split(definition, " DEFAULT ", parts: 2) do
        [type] -> %{type: type, default: nil, not_null: not_null}
        [type, default] -> %{type: type, default: default, not_null: not_null}
      end
    end
  end
end
