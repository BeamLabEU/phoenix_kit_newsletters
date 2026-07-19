defmodule PhoenixKit.Newsletters.Web.OneClickUnsubscribeUserFlavorTest do
  @moduledoc """
  Same coverage as `OneClickUnsubscribeTest`, but for the newsletters_list
  (`user_uuid`/`list_uuid`) token flavor. Previously the one-click POST
  handler only matched the crm_list claim shape and silently fell
  through to the catch-all `_ -> :ok` for this flavor — a mail client's
  List-Unsubscribe-Post request looked successful (always 200) but never
  actually unsubscribed the user.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.ListMember
  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.Repo

  defp sign_token(user_uuid, list_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

    Phoenix.Token.sign(endpoint, "unsubscribe", %{
      user_uuid: user_uuid,
      list_uuid: list_uuid
    })
  end

  defp build_conn(method) do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(method, "/newsletters/unsubscribe/one-click")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
  end

  defp create_user_and_list do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "one-click-list-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    {:ok, list} =
      Newsletters.create_list(%{
        name: "One-click list test #{System.unique_integer([:positive])}",
        slug: "one-click-list-#{System.unique_integer([:positive])}"
      })

    {:ok, member} = Newsletters.subscribe_user(list.uuid, user.uuid)

    %{user: user, list: list, member: member}
  end

  describe "GET — must never mutate" do
    test "leaves the membership subscribed and redirects to the interactive confirm page" do
      %{user: user, list: list, member: member} = create_user_and_list()
      token = sign_token(user.uuid, list.uuid)

      conn =
        build_conn(:get)
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "/newsletters/unsubscribe"

      reloaded = Repo.get_by(ListMember, uuid: member.uuid)
      assert reloaded.status == "active"
    end
  end

  describe "POST — the actual mutation" do
    test "unsubscribes the user from the list and returns a blank 200" do
      %{user: user, list: list, member: member} = create_user_and_list()
      token = sign_token(user.uuid, list.uuid)

      conn =
        build_conn(:post)
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert conn.status == 200
      assert conn.resp_body == ""

      reloaded = Repo.get_by(ListMember, uuid: member.uuid)
      assert reloaded.status == "unsubscribed"
    end

    test "idempotent — a repeat POST on an already-unsubscribed membership stays 200, no crash" do
      %{user: user, list: list, member: member} = create_user_and_list()
      token = sign_token(user.uuid, list.uuid)

      assert %{status: 200} =
               build_conn(:post)
               |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert %{status: 200} =
               build_conn(:post)
               |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      reloaded = Repo.get_by(ListMember, uuid: member.uuid)
      assert reloaded.status == "unsubscribed"
    end
  end
end
