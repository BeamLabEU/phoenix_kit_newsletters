defmodule PhoenixKit.Newsletters.Delivery do
  @moduledoc """
  Ecto schema for per-recipient delivery tracking.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  # "blocked" = the recipient is on the suppression list; the send was
  # correctly refused. Distinct from "failed"/"bounced" so it never
  # pollutes bounce metrics.
  @valid_statuses ["pending", "sent", "delivered", "opened", "bounced", "failed", "blocked"]

  schema "phoenix_kit_newsletters_deliveries" do
    field(:status, :string, default: "pending")
    field(:sent_at, :utc_datetime)
    field(:delivered_at, :utc_datetime)
    field(:opened_at, :utc_datetime)
    field(:error, :string)
    field(:message_id, :string)
    field(:broadcast_uuid, UUIDv7)
    field(:user_uuid, UUIDv7)
    # Snapshot of the recipient's address, taken when the send is enqueued —
    # the only identifier a CRM-sourced delivery has, since most CRM
    # contacts have no core User row at all. Always set for a CRM-sourced
    # delivery; nil for a newsletters-list delivery (user.email covers it).
    field(:recipient_email, :string)

    belongs_to(:broadcast, PhoenixKit.Newsletters.Broadcast,
      foreign_key: :broadcast_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    belongs_to(:user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :broadcast_uuid,
      :user_uuid,
      :recipient_email,
      :status,
      :sent_at,
      :delivered_at,
      :opened_at,
      :error,
      :message_id
    ])
    |> validate_required([:broadcast_uuid])
    |> validate_recipient()
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:message_id, name: :idx_newsletters_deliveries_message_id)
  end

  # A delivery must be addressable by exactly one of the two recipient
  # identifiers — a core User (newsletters-list path) or a snapshotted
  # email (CRM-list path). Neither present means nobody to send to.
  defp validate_recipient(changeset) do
    if get_field(changeset, :user_uuid) || get_field(changeset, :recipient_email) do
      changeset
    else
      add_error(changeset, :user_uuid, "either user_uuid or recipient_email is required")
    end
  end

  def valid_statuses, do: @valid_statuses
end
