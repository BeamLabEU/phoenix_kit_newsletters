defmodule PhoenixKitNewsletters.RenamedHostFixture do
  @moduledoc """
  The shape of a host whose own migration renamed the pre-`newsletters` tables
  (`ALTER TABLE ... RENAME TO` leaves a table's constraints and indexes under
  their original names): both tables with the current V135-through-V158
  columns, but every constraint and index the rename could have touched under
  its pre-rename `phoenix_kit_mailing_*` / `fk_mailing_*` / `idx_mailing_*`
  name. The objects introduced after the rename (the CHECKs, the CRM and
  unique-per-broadcast indexes) carry their current names, as they do on such
  a host.

  Built inside a prefix schema, with two one-column stub tables standing in
  for `phoenix_kit_users` / `phoenix_kit_email_templates` so the real FKs have
  something to reference. Used by `migrations_renamed_host_test.exs` and
  `migrations_legacy_names_test.exs`.
  """

  alias PhoenixKitNewsletters.Test.Repo

  @doc "Creates the schema `prefix` and the renamed-host tables in it."
  @spec create!(String.t()) :: :ok
  def create!(prefix) do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{prefix}")

    Repo.query!("""
    CREATE TABLE #{prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)
    """)

    Repo.query!("""
    CREATE TABLE #{prefix}.phoenix_kit_email_templates (uuid uuid PRIMARY KEY)
    """)

    # The exact current (V135-through-V158) column shape, so every guard
    # finds the columns it expects — only the PK/FK/index OBJECT NAMES are
    # the pre-rename legacy ones. `gen_random_uuid()` (pgcrypto, already
    # ensured by the main test suite's own migration bootstrap) stands in
    # for `uuid_generate_v7()` — irrelevant here, no row is ever inserted.
    Repo.query!("""
    CREATE TABLE #{prefix}.phoenix_kit_newsletters_broadcasts (
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
      CONSTRAINT phoenix_kit_mailing_broadcasts_pkey PRIMARY KEY (uuid),
      CONSTRAINT phoenix_kit_newsletters_broadcasts_attachments_is_array
        CHECK (jsonb_typeof(attachments) = 'array')
    )
    """)

    Repo.query!("""
    CREATE TABLE #{prefix}.phoenix_kit_newsletters_deliveries (
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
      CONSTRAINT phoenix_kit_mailing_deliveries_pkey PRIMARY KEY (uuid),
      CONSTRAINT phoenix_kit_newsletters_deliveries_recipient_check
        CHECK ((user_uuid IS NOT NULL OR recipient_email IS NOT NULL)
               AND NOT (user_uuid IS NOT NULL AND crm_contact_uuid IS NOT NULL))
    )
    """)

    Repo.query!("""
    ALTER TABLE #{prefix}.phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT fk_mailing_broadcasts_created_by FOREIGN KEY (created_by_user_uuid)
      REFERENCES #{prefix}.phoenix_kit_users(uuid) ON DELETE SET NULL
    """)

    Repo.query!("""
    ALTER TABLE #{prefix}.phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT fk_mailing_broadcasts_template FOREIGN KEY (template_uuid)
      REFERENCES #{prefix}.phoenix_kit_email_templates(uuid) ON DELETE SET NULL
    """)

    Repo.query!("""
    ALTER TABLE #{prefix}.phoenix_kit_newsletters_deliveries
      ADD CONSTRAINT fk_mailing_deliveries_broadcast FOREIGN KEY (broadcast_uuid)
      REFERENCES #{prefix}.phoenix_kit_newsletters_broadcasts(uuid) ON DELETE CASCADE
    """)

    Repo.query!("""
    ALTER TABLE #{prefix}.phoenix_kit_newsletters_deliveries
      ADD CONSTRAINT fk_mailing_deliveries_user FOREIGN KEY (user_uuid)
      REFERENCES #{prefix}.phoenix_kit_users(uuid) ON DELETE CASCADE
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_broadcasts_scheduled_at ON #{prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_broadcasts_status ON #{prefix}.phoenix_kit_newsletters_broadcasts
      USING btree (status)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_deliveries_broadcast ON #{prefix}.phoenix_kit_newsletters_deliveries
      USING btree (broadcast_uuid)
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX idx_mailing_deliveries_message_id ON #{prefix}.phoenix_kit_newsletters_deliveries
      USING btree (message_id) WHERE (message_id IS NOT NULL)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_deliveries_status ON #{prefix}.phoenix_kit_newsletters_deliveries
      USING btree (status)
    """)

    Repo.query!("""
    CREATE INDEX idx_mailing_deliveries_user ON #{prefix}.phoenix_kit_newsletters_deliveries
      USING btree (user_uuid)
    """)

    :ok
  end
end
