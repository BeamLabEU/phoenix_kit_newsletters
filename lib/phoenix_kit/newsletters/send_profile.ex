defmodule PhoenixKit.Newsletters.SendProfile do
  @moduledoc """
  Ecto schema for newsletter send profiles ("Send Settings").

  A send profile references a core `PhoenixKit.Integrations` connection
  (by `integration_uuid` — no FK, since integrations live in
  `phoenix_kit_settings`) and carries per-account send parameters: sender
  identity, signature, rate limits, and provider-specific `advanced`
  extras. Multiple profiles may share one integration. At most one
  profile may be `is_default` (the service-wide default), enforced by a
  partial unique index on `phoenix_kit_newsletters_send_profiles`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_provider_kinds ~w(aws_ses smtp brevo_api)

  schema "phoenix_kit_newsletters_send_profiles" do
    field(:name, :string)
    field(:integration_uuid, UUIDv7)
    field(:provider_kind, :string)
    field(:from_name, :string)
    field(:from_email, :string)
    field(:reply_to, :string)
    field(:signature_html, :string)
    field(:signature_text, :string)
    field(:rate_per_hour, :integer)
    field(:rate_per_day, :integer)
    field(:pause_seconds, :integer, default: 0)
    field(:advanced, :map, default: %{})
    field(:enabled, :boolean, default: true)
    field(:is_default, :boolean, default: false)

    timestamps(type: :utc_datetime)
  end

  def changeset(send_profile, attrs) do
    send_profile
    |> cast(attrs, [
      :name,
      :integration_uuid,
      :provider_kind,
      :from_name,
      :from_email,
      :reply_to,
      :signature_html,
      :signature_text,
      :rate_per_hour,
      :rate_per_day,
      :pause_seconds,
      :advanced,
      :enabled,
      :is_default
    ])
    |> validate_required([:name, :integration_uuid, :provider_kind])
    |> validate_inclusion(:provider_kind, @valid_provider_kinds)
    |> validate_number(:rate_per_hour, greater_than_or_equal_to: 0)
    |> validate_number(:rate_per_day, greater_than_or_equal_to: 0)
    |> validate_number(:pause_seconds, greater_than_or_equal_to: 0)
    |> validate_provider_kind_matches_integration()
    |> unique_constraint(:is_default,
      name: :idx_nl_send_profiles_default,
      message: "another profile is already the default"
    )
  end

  def valid_provider_kinds, do: @valid_provider_kinds

  # Cross-field consistency: the profile's declared provider_kind must
  # match the actual provider of the integration it points at, so the two
  # sources of truth (this row's provider_kind vs. the Integrations
  # connection's real provider) can't drift apart. Only runs once both
  # fields resolve to a value — validate_required/inclusion already cover
  # the missing/invalid cases on their own. Adds a :base error (rather
  # than crashing) when the integration can't be found, e.g. it was
  # deleted after this profile was created.
  defp validate_provider_kind_matches_integration(changeset) do
    integration_uuid = get_field(changeset, :integration_uuid)
    provider_kind = get_field(changeset, :provider_kind)

    if is_binary(integration_uuid) and is_binary(provider_kind) do
      case PhoenixKit.Integrations.get_integration_by_uuid(integration_uuid) do
        {:ok, %{provider: ^provider_kind}} ->
          changeset

        {:ok, %{provider: actual_provider}} ->
          add_error(
            changeset,
            :base,
            "provider_kind (#{provider_kind}) does not match the integration's provider (#{actual_provider})"
          )

        {:error, _} ->
          add_error(changeset, :base, "integration not found")
      end
    else
      changeset
    end
  end
end
