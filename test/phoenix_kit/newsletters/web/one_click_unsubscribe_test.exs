defmodule PhoenixKit.Newsletters.Web.OneClickUnsubscribeTest do
  @moduledoc """
  Real tests for `UnsubscribeController.one_click_unsubscribe/2` — the
  RFC 8058 List-Unsubscribe(-Post) header target. GLM flagged that this
  endpoint had no tests at all (the neighboring test file's trailing
  comment claimed "verified live", but that comment described the
  *interactive* endpoint, not this one — a masking gap).

  This turned out to be directly testable, contrary to the assumption
  elsewhere in this test suite that `Phoenix.Token`-touching code needs a
  running `PhoenixKitWeb.Endpoint`: `config/test.exs` configures
  `:endpoint` as a raw secret **string**, not a Phoenix.Endpoint module,
  and `Phoenix.Token.sign/3` + `verify/4` both accept a raw binary
  context directly — no running process needed. `DataCase` is used only
  because the CRM fixtures (`PhoenixKitCRM.Contacts`/`Lists`) need a real
  DB, not because of the token.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  defp sign_token(contact_uuid, crm_list_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

    Phoenix.Token.sign(endpoint, "unsubscribe", %{
      contact_uuid: contact_uuid,
      crm_list_uuid: crm_list_uuid
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

  defp create_list_and_contact do
    {:ok, list} =
      Lists.create_list(%{name: "One-click test list #{System.unique_integer([:positive])}"})

    {:ok, contact} =
      Contacts.create_contact(%{
        name: "One Click",
        email: "one-click-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, member} = Lists.add_contact_to_list(contact, list, source: "manual")

    %{list: list, contact: contact, member: member}
  end

  describe "GET — must never mutate" do
    test "leaves the membership subscribed and redirects to the interactive confirm page" do
      %{list: list, contact: contact, member: member} = create_list_and_contact()
      token = sign_token(contact.uuid, list.uuid)

      conn =
        build_conn(:get)
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "/newsletters/unsubscribe"
      assert location =~ URI.encode_www_form(token) or location =~ token

      reloaded = Repo.get_by(member.__struct__, uuid: member.uuid)
      assert reloaded.status == "subscribed"
    end

    test "with no token param redirects home and still doesn't touch the DB" do
      %{member: member} = create_list_and_contact()

      conn =
        build_conn(:get)
        |> UnsubscribeController.one_click_unsubscribe(%{})

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "/"

      reloaded = Repo.get_by(member.__struct__, uuid: member.uuid)
      assert reloaded.status == "subscribed"
    end
  end

  describe "POST — the actual mutation" do
    test "removes the membership and returns a blank 200" do
      %{list: list, contact: contact, member: member} = create_list_and_contact()
      token = sign_token(contact.uuid, list.uuid)

      conn =
        build_conn(:post)
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert conn.status == 200
      assert conn.resp_body == ""

      reloaded = Repo.get_by(member.__struct__, uuid: member.uuid)
      assert reloaded.status == "removed"
    end

    test "a garbage token still returns 200 without crashing or mutating anything" do
      %{member: member} = create_list_and_contact()

      conn =
        build_conn(:post)
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => "not-a-real-token"})

      assert conn.status == 200
      assert conn.resp_body == ""

      reloaded = Repo.get_by(member.__struct__, uuid: member.uuid)
      assert reloaded.status == "subscribed"
    end

    test "no token param at all still returns 200 without crashing" do
      conn =
        build_conn(:post)
        |> UnsubscribeController.one_click_unsubscribe(%{})

      assert conn.status == 200
      assert conn.resp_body == ""
    end

    test "idempotent — a repeat POST on an already-removed membership stays 200, no crash" do
      %{list: list, contact: contact, member: member} = create_list_and_contact()
      token = sign_token(contact.uuid, list.uuid)

      assert %{status: 200} =
               build_conn(:post)
               |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert %{status: 200} =
               build_conn(:post)
               |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      reloaded = Repo.get_by(member.__struct__, uuid: member.uuid)
      assert reloaded.status == "removed"
    end
  end
end
