defmodule PhoenixKit.Newsletters.Broadcast do
  @moduledoc """
  Ecto schema for newsletter broadcasts.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["draft", "scheduled", "sending", "sent", "cancelled", "failed"]
  @valid_source_types ["newsletters_list", "crm_list", "user_group"]

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
    field(:list_uuid, UUIDv7)
    field(:created_by_user_uuid, UUIDv7)
    field(:send_profile_uuid, UUIDv7)
    # "newsletters_list" (default) sends to this broadcast's own `list_uuid`;
    # "crm_list" sends to `crm_list_uuid` instead — a bare UUID, deliberately
    # with no belongs_to/FK, same soft-reference pattern as send_profile_uuid:
    # newsletters must not hard-depend on the CRM module being installed.
    # "user_group" sends to `source_params`'s role selection instead — core
    # roles are a hard dependency already, so no soft-reference is needed
    # there, but a broadcast can target more than one role, so a scalar
    # uuid column doesn't fit; see UserGroupSource.
    field(:source_type, :string, default: "newsletters_list")
    field(:crm_list_uuid, UUIDv7)
    field(:source_params, :map, default: %{})

    belongs_to(:list, PhoenixKit.Newsletters.List,
      foreign_key: :list_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

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
      :list_uuid,
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
  # one role name in source_params, and anything else (newsletters_list)
  # needs list_uuid.
  defp validate_source_reference(changeset) do
    case get_field(changeset, :source_type) do
      "crm_list" -> validate_required(changeset, [:crm_list_uuid])
      "user_group" -> validate_role_names_present(changeset)
      _ -> validate_required(changeset, [:list_uuid])
    end
  end

  defp validate_role_names_present(changeset) do
    if changeset |> get_field(:source_params) |> role_names() != [] do
      changeset
    else
      add_error(changeset, :source_params, "select at least one role")
    end
  end

  @doc "The role names selected for a `user_group` broadcast's `source_params`, or `[]`."
  @spec role_names(%__MODULE__{} | map() | nil) :: [String.t()]
  def role_names(%__MODULE__{source_params: source_params}), do: role_names(source_params)

  def role_names(%{"role_names" => role_names}) when is_list(role_names), do: role_names
  def role_names(_), do: []

  def valid_statuses, do: @valid_statuses
  def valid_source_types, do: @valid_source_types
end
