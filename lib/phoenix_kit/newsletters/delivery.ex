defmodule PhoenixKit.Newsletters.Delivery do
  @moduledoc """
  Ecto schema for per-recipient delivery tracking.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  # "blocked" = the recipient is on the suppression list; the send was
  # correctly refused. Distinct from "failed"/"bounced" so it never
  # pollutes bounce metrics.
  @valid_statuses ["pending", "sent", "delivered", "opened", "bounced", "failed", "blocked"]

  # The only status meaning "no send attempt has been made yet." Every
  # other status has some attempt behind it — including "failed" on a
  # delivery Oban will still retry (DeliveryWorker.handle_failure/4 marks a
  # non-terminal transient failure "failed" too, purely for UI visibility),
  # so a delivery leaving "pending" doesn't guarantee Oban is done with it,
  # only that dispatch has started. Broadcast finalization (below) treats
  # "started" as good enough — the same way it already doesn't wait for
  # delivered/opened webhooks once a message is "sent"; a still-retrying
  # delivery only delays the status flip by the retry's backoff window, and
  # its counter still lands correctly in the background regardless.
  @non_terminal_statuses ["pending"]

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
    |> unique_constraint(:message_id)
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

  @doc false
  # UUIDs of every broadcast that still has at least one delivery in a
  # non-terminal status — i.e. broadcasts that are NOT yet safe to
  # finalize. Shared by Newsletters.repair_stuck_sending_broadcasts/0 (all
  # "sending" broadcasts, one batch statement) and
  # DeliveryWorker.maybe_finalize_broadcast/1 (a single broadcast, checked
  # right after each delivery's status transition) via `not in
  # subquery(...)`, so the completion definition lives in exactly one
  # place. Built from `@non_terminal_statuses` (not raw SQL), so it
  # automatically targets this schema's configured `@schema_prefix`.
  def non_terminal_broadcast_uuids_query do
    from(d in __MODULE__,
      where: d.status in ^@non_terminal_statuses,
      select: d.broadcast_uuid,
      distinct: true
    )
  end
end
