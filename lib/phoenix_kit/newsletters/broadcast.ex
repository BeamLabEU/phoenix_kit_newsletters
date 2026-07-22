defmodule PhoenixKit.Newsletters.Broadcast do
  @moduledoc """
  Ecto schema for newsletter broadcasts.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["draft", "scheduled", "sending", "sent", "cancelled", "failed"]
  @valid_source_types ["crm_list", "user_group"]

  schema "phoenix_kit_newsletters_broadcasts" do
    field(:subject, :string)
    field(:markdown_body, :string)
    field(:html_body, :string)
    field(:text_body, :string)
    field(:status, :string, default: "draft")
    field(:scheduled_at, :utc_datetime)
    field(:sent_at, :utc_datetime)
    field(:total_recipients, :integer, default: 0)
    field(:sent_count, :integer, default: 0)
    field(:delivered_count, :integer, default: 0)
    field(:opened_count, :integer, default: 0)
    field(:bounced_count, :integer, default: 0)
    field(:template_uuid, UUIDv7)
    field(:created_by_user_uuid, UUIDv7)
    field(:send_profile_uuid, UUIDv7)
    # "crm_list" (default) sends to `crm_list_uuid` — a bare UUID,
    # deliberately with no belongs_to/FK, same soft-reference pattern as
    # send_profile_uuid: newsletters must not hard-depend on the CRM
    # module being installed. "user_group" sends to `source_params`'s
    # role selection instead — core roles are a hard dependency already,
    # so no soft-reference is needed there, but a broadcast can target
    # more than one role, so a scalar uuid column doesn't fit; see
    # UserGroupSource. `source_params` stores `%{"role_uuids" => [...],
    # "role_names_snapshot" => [...]}` — uuids because a role's `name`
    # is mutable (Roles.update_role/2 doesn't protect it even for system
    # roles), so resolving by name would let a rename silently re-point
    # (or empty out) an already-saved broadcast; the name snapshot is
    # display-only, same precedent as `recipient_email`/
    # `supplier_name_snapshot` elsewhere in this ecosystem — it shows
    # what the broadcast targeted even after a role is renamed or
    # deleted, while resolution stays on the stable uuid.
    #
    # A third source_type, "newsletters_list", existed here until this
    # module's own List/ListMember tables (and the list_uuid field that
    # went with it) were dropped in core V156 — see this repo's S4-E
    # removal. The DB COLUMN default is still literally
    # 'newsletters_list'::character varying (core-owned DDL, out of
    # scope for a newsletters-side change — see that PR's notes for the
    # follow-up); this Ecto-level default is what every INSERT going
    # through this changeset actually uses instead.
    field(:source_type, :string, default: "crm_list")
    field(:crm_list_uuid, UUIDv7)
    field(:source_params, :map, default: %{})

    # belongs_to :template removed — Emails module is an optional soft dependency.
    # template_uuid field kept for DB compatibility.
    # Use Newsletters.get_broadcast_with_template!/1 for optional template loading.

    belongs_to(:created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    belongs_to(:send_profile, PhoenixKit.Email.SendProfile,
      foreign_key: :send_profile_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    has_many(:deliveries, PhoenixKit.Newsletters.Delivery,
      foreign_key: :broadcast_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  def changeset(broadcast, attrs) do
    broadcast
    |> cast(attrs, [
      :subject,
      :markdown_body,
      :html_body,
      :text_body,
      :status,
      :scheduled_at,
      :sent_at,
      :total_recipients,
      :sent_count,
      :delivered_count,
      :opened_count,
      :bounced_count,
      :template_uuid,
      :created_by_user_uuid,
      :send_profile_uuid,
      :source_type,
      :crm_list_uuid,
      :source_params
    ])
    |> validate_required([:subject])
    |> validate_length(:subject, min: 1, max: 998)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:source_type, @valid_source_types)
    |> validate_source_reference()
  end

  # The source-specific reference is required only for the matching
  # source_type: crm_list needs crm_list_uuid, user_group needs at least
  # one role uuid in source_params. Any other value already failed
  # validate_inclusion/3 above — nothing further to require here.
  defp validate_source_reference(changeset) do
    case get_field(changeset, :source_type) do
      "crm_list" -> validate_required(changeset, [:crm_list_uuid])
      "user_group" -> validate_role_uuids_present(changeset)
      _ -> changeset
    end
  end

  defp validate_role_uuids_present(changeset) do
    if changeset |> get_field(:source_params) |> role_uuids() != [] do
      changeset
    else
      add_error(changeset, :source_params, "select at least one role")
    end
  end

  @doc "The role uuids selected for a `user_group` broadcast's `source_params`, or `[]`."
  @spec role_uuids(%__MODULE__{} | map() | nil) :: [String.t()]
  def role_uuids(%__MODULE__{source_params: source_params}), do: role_uuids(source_params)
  def role_uuids(%{"role_uuids" => role_uuids}) when is_list(role_uuids), do: role_uuids
  def role_uuids(_), do: []

  @doc """
  The role NAMES as they were at save time, for display only — resolving
  a `user_group` broadcast's actual recipients always goes through
  `role_uuids/1`, never this. Stays `[]` if unset.
  """
  @spec role_names_snapshot(%__MODULE__{} | map() | nil) :: [String.t()]
  def role_names_snapshot(%__MODULE__{source_params: source_params}),
    do: role_names_snapshot(source_params)

  def role_names_snapshot(%{"role_names_snapshot" => names}) when is_list(names), do: names
  def role_names_snapshot(_), do: []

  def valid_statuses, do: @valid_statuses
  def valid_source_types, do: @valid_source_types
end
