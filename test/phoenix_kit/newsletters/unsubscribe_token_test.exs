defmodule PhoenixKitNewslettersFakeHostWeb.Endpoint do
  @moduledoc false
  # What a host's endpoint looks like to `Config.get_parent_endpoint/0` and to
  # `Phoenix.Token`.
  def url, do: "https://host.example"
  def config(:secret_key_base, _default \\ nil), do: String.duplicate("h", 64)
end

defmodule PhoenixKit.Newsletters.UnsubscribeTokenTest do
  @moduledoc """
  `config/test.exs` sets `:endpoint` to a raw secret, which a host does not do, so
  the rest of the suite never sees how a token finds its secret on a real site.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Newsletters.PreferenceToken
  alias PhoenixKit.Newsletters.UnsubscribeToken

  @long_ago 60 * 60 * 24 * 400

  describe "on a host, which sets no :endpoint" do
    setup do
      endpoint = Application.get_env(:phoenix_kit, :endpoint)
      parent = Application.get_env(:phoenix_kit, :parent_module)

      Application.delete_env(:phoenix_kit, :endpoint)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKitNewslettersFakeHost)

      on_exit(fn ->
        Application.put_env(:phoenix_kit, :endpoint, endpoint)

        if parent,
          do: Application.put_env(:phoenix_kit, :parent_module, parent),
          else: Application.delete_env(:phoenix_kit, :parent_module)
      end)

      :ok
    end

    test "tokens are signed with the host's own endpoint" do
      assert UnsubscribeToken.endpoint() == PhoenixKitNewslettersFakeHostWeb.Endpoint
    end

    test "signing and verifying work, which on core's unstarted endpoint both raise" do
      assert_raise ArgumentError, fn ->
        Phoenix.Token.sign(PhoenixKitWeb.Endpoint, "unsubscribe", %{})
      end

      token = UnsubscribeToken.sign_list("contact", "list")

      assert {:ok, %{contact_uuid: "contact", crm_list_uuid: "list"}} =
               UnsubscribeToken.verify(token)

      assert {:role_optout, %{user_uuid: "user"}} =
               "user" |> UnsubscribeToken.sign_role() |> UnsubscribeToken.verify()
    end

    test "the preference token finds it too" do
      assert {:ok, "contact"} = "contact" |> PreferenceToken.sign() |> PreferenceToken.verify()
    end

    test "with no parent either, core's endpoint is what is left" do
      Application.delete_env(:phoenix_kit, :parent_module)

      assert UnsubscribeToken.endpoint() == PhoenixKitWeb.Endpoint
    end
  end

  test "an explicit :endpoint wins" do
    assert UnsubscribeToken.endpoint() == Application.get_env(:phoenix_kit, :endpoint)
  end

  describe "verify/1" do
    # Mail is read long after it is sent, and the opt-out has to keep working.
    test "accepts a token of any age, under either salt" do
      signed_at = System.system_time(:second) - @long_ago
      endpoint = UnsubscribeToken.endpoint()

      list = Phoenix.Token.sign(endpoint, "unsubscribe", %{a: 1}, signed_at: signed_at)

      role =
        Phoenix.Token.sign(endpoint, "newsletters_user_optout", %{b: 2}, signed_at: signed_at)

      assert {:ok, %{a: 1}} = UnsubscribeToken.verify(list)
      assert {:role_optout, %{b: 2}} = UnsubscribeToken.verify(role)
    end

    test "tells the two kinds apart" do
      assert {:ok, _claims} = "c" |> UnsubscribeToken.sign_list("l") |> UnsubscribeToken.verify()
      assert {:role_optout, _} = "u" |> UnsubscribeToken.sign_role() |> UnsubscribeToken.verify()
    end

    test "refuses a preference token, which can do more" do
      assert {:error, _reason} = "c" |> PreferenceToken.sign() |> UnsubscribeToken.verify()
    end

    test "refuses what is not a token, without raising" do
      assert {:error, _reason} = UnsubscribeToken.verify("garbage")
      assert {:error, :invalid} = UnsubscribeToken.verify(%{"a" => "b"})
      assert {:error, :invalid} = UnsubscribeToken.verify(nil)
    end
  end
end
