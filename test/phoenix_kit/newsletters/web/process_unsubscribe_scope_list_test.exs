defmodule PhoenixKit.Newsletters.Web.ProcessUnsubscribeScopeListTest do
  @moduledoc """
  Tests for `UnsubscribeController.process_unsubscribe/2`'s `scope=list`
  newsletters-list branch — previously untested (see the trailing comment
  in the neighboring unsubscribe_controller_test.exs). This branch
  discarded `Newsletters.unsubscribe_user/2`'s result entirely, exactly
  the bug pattern already found and fixed for the sibling `scope=all`
  crm_list branch in commit dc4402a — a stale token (list/membership
  already gone) silently rendered the same "unsubscribed" success flash
  as a real success, leaving the user still subscribed with no error
  surfaced anywhere.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.Repo

  defp sign_token(user_uuid, list_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    Phoenix.Token.sign(endpoint, "unsubscribe", %{user_uuid: user_uuid, list_uuid: list_uuid})
  end

  defp build_conn do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(:post, "/newsletters/unsubscribe")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
  end

  defp create_user do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "scope-list-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    user
  end

  defp create_list do
    {:ok, list} =
      Newsletters.create_list(%{
        name: "Scope List Test",
        slug: "scope-list-test-#{System.unique_integer([:positive])}"
      })

    list
  end

  test "unsubscribes an active member and shows the success flash" do
    user = create_user()
    list = create_list()
    {:ok, _member} = Newsletters.subscribe_user(list.uuid, user.uuid)

    token = sign_token(user.uuid, list.uuid)

    conn =
      build_conn()
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "list"})

    assert conn.status == 302
    assert conn.assigns[:flash]["info"] =~ "unsubscribed from this list"
    refute conn.assigns[:flash]["error"]

    members = Newsletters.list_members(list.uuid, %{status: "active"})
    refute Enum.any?(members, &(&1.user_uuid == user.uuid))
  end

  test "a stale token (no matching membership) shows an error flash, not the success text" do
    user = create_user()
    list = create_list()
    # Deliberately no subscribe_user/2 call — the membership row this
    # token references does not exist (already removed, or never existed).

    token = sign_token(user.uuid, list.uuid)

    conn =
      build_conn()
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "list"})

    assert conn.status == 302
    assert conn.assigns[:flash]["error"] =~ "We could not unsubscribe you right now."
    refute conn.assigns[:flash]["info"]
  end
end
