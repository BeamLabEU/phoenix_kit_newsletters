defmodule PhoenixKit.Newsletters.SendProfileTest do
  @moduledoc """
  Tests for the SendProfile schema/changeset and the Newsletters context's
  send-profile CRUD + default management (Stage D, D2).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.SendProfile

  defp add_integration(provider \\ "smtp", name \\ "test connection") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    uuid
  end

  defp valid_attrs(overrides \\ %{}) do
    integration_uuid = overrides[:integration_uuid] || add_integration()

    Map.merge(
      %{
        name: "Marketing",
        integration_uuid: integration_uuid,
        provider_kind: "smtp"
      },
      overrides
    )
  end

  describe "changeset/2 — required fields" do
    test "requires name, integration_uuid, provider_kind" do
      changeset = SendProfile.changeset(%SendProfile{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.integration_uuid
      assert "can't be blank" in errors.provider_kind
    end

    test "is valid with only the required fields plus a matching integration" do
      changeset = SendProfile.changeset(%SendProfile{}, valid_attrs())
      assert changeset.valid?
    end
  end

  describe "changeset/2 — provider_kind inclusion" do
    test "rejects a provider_kind outside aws_ses/smtp/brevo_api" do
      changeset = SendProfile.changeset(%SendProfile{}, valid_attrs(%{provider_kind: "mailgun"}))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).provider_kind
    end

    test "accepts each of aws_ses, smtp, brevo_api" do
      for provider <- ~w(aws_ses smtp brevo_api) do
        integration_uuid = add_integration(provider)

        changeset =
          SendProfile.changeset(
            %SendProfile{},
            valid_attrs(%{provider_kind: provider, integration_uuid: integration_uuid})
          )

        assert changeset.valid?,
               "expected #{provider} to be valid, got: #{inspect(changeset.errors)}"
      end
    end
  end

  describe "changeset/2 — rate validation" do
    test "rejects negative rate_per_hour, rate_per_day, pause_seconds" do
      changeset =
        SendProfile.changeset(
          %SendProfile{},
          valid_attrs(%{rate_per_hour: -1, rate_per_day: -5, pause_seconds: -10})
        )

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "must be greater than or equal to 0" in errors.rate_per_hour
      assert "must be greater than or equal to 0" in errors.rate_per_day
      assert "must be greater than or equal to 0" in errors.pause_seconds
    end

    test "accepts zero and positive rates, and nil (unset) rates" do
      changeset =
        SendProfile.changeset(
          %SendProfile{},
          valid_attrs(%{rate_per_hour: 0, rate_per_day: 500, pause_seconds: 2})
        )

      assert changeset.valid?
    end
  end

  describe "changeset/2 — provider_kind must match the integration's real provider" do
    test "rejects a mismatch between provider_kind and the integration's provider" do
      integration_uuid = add_integration("aws_ses")

      changeset =
        SendProfile.changeset(
          %SendProfile{},
          valid_attrs(%{integration_uuid: integration_uuid, provider_kind: "smtp"})
        )

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).base, &(&1 =~ "does not match"))
    end

    test "adds a base error (does not crash) when the integration cannot be found" do
      missing_uuid = Ecto.UUID.generate()

      changeset =
        SendProfile.changeset(%SendProfile{}, valid_attrs(%{integration_uuid: missing_uuid}))

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).base, &(&1 =~ "not found"))
    end
  end

  describe "context CRUD" do
    test "two profiles may share one integration_uuid" do
      integration_uuid = add_integration()

      assert {:ok, profile_a} =
               Newsletters.create_send_profile(
                 valid_attrs(%{name: "Profile A", integration_uuid: integration_uuid})
               )

      assert {:ok, profile_b} =
               Newsletters.create_send_profile(
                 valid_attrs(%{name: "Profile B", integration_uuid: integration_uuid})
               )

      assert profile_a.integration_uuid == profile_b.integration_uuid
      assert profile_a.uuid != profile_b.uuid
    end

    test "list_send_profiles/0, get_send_profile!/1, get_send_profile/1" do
      {:ok, profile} = Newsletters.create_send_profile(valid_attrs(%{name: "Zeta"}))
      {:ok, _other} = Newsletters.create_send_profile(valid_attrs(%{name: "Alpha"}))

      names = Newsletters.list_send_profiles() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)

      assert Newsletters.get_send_profile!(profile.uuid).uuid == profile.uuid
      assert Newsletters.get_send_profile(profile.uuid).uuid == profile.uuid
      assert Newsletters.get_send_profile(Ecto.UUID.generate()) == nil
    end

    test "update_send_profile/2 persists changes" do
      {:ok, profile} = Newsletters.create_send_profile(valid_attrs())

      assert {:ok, updated} =
               Newsletters.update_send_profile(profile, %{from_name: "Support Team"})

      assert updated.from_name == "Support Team"
    end

    test "delete_send_profile/1 removes the row" do
      {:ok, profile} = Newsletters.create_send_profile(valid_attrs())
      assert {:ok, _} = Newsletters.delete_send_profile(profile)
      assert Newsletters.get_send_profile(profile.uuid) == nil
    end
  end

  describe "default profile get/set" do
    test "get_default_send_profile/0 returns nil when none is set" do
      assert Newsletters.get_default_send_profile() == nil
    end

    test "set_default_send_profile/1 marks a profile as default" do
      {:ok, profile} = Newsletters.create_send_profile(valid_attrs())

      assert {:ok, updated} = Newsletters.set_default_send_profile(profile)
      assert updated.is_default == true
      assert Newsletters.get_default_send_profile().uuid == profile.uuid
    end

    test "setting a new default clears the previous default" do
      {:ok, first} = Newsletters.create_send_profile(valid_attrs(%{name: "First"}))
      {:ok, second} = Newsletters.create_send_profile(valid_attrs(%{name: "Second"}))

      assert {:ok, _} = Newsletters.set_default_send_profile(first)
      assert Newsletters.get_default_send_profile().uuid == first.uuid

      assert {:ok, _} = Newsletters.set_default_send_profile(second)

      assert Newsletters.get_default_send_profile().uuid == second.uuid
      refute Newsletters.get_send_profile!(first.uuid).is_default
    end
  end
end
