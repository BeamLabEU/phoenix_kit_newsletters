defmodule PhoenixKit.Newsletters.DeliveryTest do
  @moduledoc """
  Changeset tests for the Stage-4 CRM recipient identifier
  (`recipient_email`, and `user_uuid` becoming optional). Pure changeset
  validation — no DB needed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Delivery

  describe "changeset/2 — recipient identifier" do
    test "valid with only user_uuid (newsletters-list path, unchanged)" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          broadcast_uuid: Ecto.UUID.generate(),
          user_uuid: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "valid with only recipient_email (CRM-list path)" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          broadcast_uuid: Ecto.UUID.generate(),
          recipient_email: "someone@example.com"
        })

      assert changeset.valid?
    end

    test "valid with both set" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          broadcast_uuid: Ecto.UUID.generate(),
          user_uuid: Ecto.UUID.generate(),
          recipient_email: "someone@example.com"
        })

      assert changeset.valid?
    end

    test "invalid with neither identifier — nobody to send to" do
      changeset = Delivery.changeset(%Delivery{}, %{broadcast_uuid: Ecto.UUID.generate()})

      refute changeset.valid?
      assert %{user_uuid: [_ | _]} = errors_on(changeset)
    end

    test "valid with crm_contact_uuid + recipient_email (CRM-list path, new shape)" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          broadcast_uuid: Ecto.UUID.generate(),
          crm_contact_uuid: Ecto.UUID.generate(),
          recipient_email: "contact@example.com"
        })

      assert changeset.valid?
    end

    test "invalid with only crm_contact_uuid — it isn't an address by itself" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          broadcast_uuid: Ecto.UUID.generate(),
          crm_contact_uuid: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{user_uuid: [_ | _]} = errors_on(changeset)
    end

    test "invalid with both user_uuid and crm_contact_uuid — mutual exclusion" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          broadcast_uuid: Ecto.UUID.generate(),
          user_uuid: Ecto.UUID.generate(),
          crm_contact_uuid: Ecto.UUID.generate(),
          recipient_email: "someone@example.com"
        })

      refute changeset.valid?
      assert %{crm_contact_uuid: [_ | _]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
