defmodule PhoenixKit.Newsletters.PreferenceTokenTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.PreferenceToken

  test "sign/1 then verify/1 round-trips the contact_uuid" do
    contact_uuid = Ecto.UUID.generate()
    token = PreferenceToken.sign(contact_uuid)

    assert {:ok, ^contact_uuid} = PreferenceToken.verify(token)
  end

  test "verify/1 rejects garbage input" do
    assert {:error, :invalid} = PreferenceToken.verify("not-a-real-token")
  end

  test "verify/1 rejects a nil/non-binary token without raising" do
    assert {:error, :invalid} = PreferenceToken.verify(nil)
  end

  # The per-list unsubscribe token (DeliveryWorker/UnsubscribeController)
  # is signed under salt "unsubscribe" — a preference-center token must
  # NOT verify under that different salt, and vice versa. This is the
  # whole point of using a separate salt (see the moduledoc): the two
  # capability classes (remove-from-one-list vs. the full self-service
  # surface) must stay non-interchangeable.
  test "a token signed under the unsubscribe salt does not verify as a preference token" do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    contact_uuid = Ecto.UUID.generate()

    foreign_token =
      Phoenix.Token.sign(endpoint, "unsubscribe", %{
        contact_uuid: contact_uuid,
        crm_list_uuid: Ecto.UUID.generate()
      })

    assert {:error, :invalid} = PreferenceToken.verify(foreign_token)
  end

  test "a preference token does not verify under the unsubscribe salt" do
    contact_uuid = Ecto.UUID.generate()
    token = PreferenceToken.sign(contact_uuid)

    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    assert {:error, _} = Phoenix.Token.verify(endpoint, "unsubscribe", token, max_age: 604_800)
  end

  test "verify/1 rejects an expired token" do
    contact_uuid = Ecto.UUID.generate()
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    # Signed "in the past" relative to the 7-day max_age, via Phoenix.Token's
    # own signed_at option — avoids sleeping in the test.
    token =
      Phoenix.Token.sign(endpoint, "newsletters_preferences", %{contact_uuid: contact_uuid},
        signed_at: System.system_time(:second) - 604_801
      )

    assert {:error, :invalid} = PreferenceToken.verify(token)
  end
end
