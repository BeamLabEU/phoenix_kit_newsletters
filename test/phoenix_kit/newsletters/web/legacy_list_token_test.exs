defmodule PhoenixKit.Newsletters.Web.LegacyListTokenTest do
  @moduledoc """
  An already-sent email can still carry a `newsletters_list`-flavor
  unsubscribe token (`%{user_uuid:, list_uuid:}`, signed under the
  "unsubscribe" salt — the same salt the surviving crm_list flavor
  still uses) for as long as `Phoenix.Token`'s 7-day `max_age` keeps it
  verifying. `phoenix_kit_newsletters_lists`/`..._list_members` are
  gone (core V156) and every clause that used to handle this claim
  shape is gone too (S4-E part 2) — this file pins that a stray one of
  these tokens degrades to the same "invalid/expired link" UX every
  other unrecognized token already gets, at all three entry points,
  rather than a `CaseClauseError` (a 500) from falling through every
  `case` clause unmatched.

  Previously (before this removal) this file tested the OPPOSITE: that
  the one-click POST handler correctly unsubscribed this flavor's user
  from the list. That coverage is retired along with the code path
  it tested — see UnsubscribeController's moduledoc comments on
  `unsubscribe/2`/`verify_token/1` for why the shape can still surface
  at all.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.Web.UnsubscribeController

  defp sign_legacy_list_token(user_uuid, list_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

    Phoenix.Token.sign(endpoint, "unsubscribe", %{
      user_uuid: user_uuid,
      list_uuid: list_uuid
    })
  end

  defp build_conn(method, path) do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
    |> Phoenix.Controller.put_view(html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)
    |> then(&%{&1 | params: Map.put(&1.params, "_format", "html")})
  end

  test "GET /newsletters/unsubscribe redirects with an 'invalid or expired' flash, not a crash" do
    token = sign_legacy_list_token(Ecto.UUID.generate(), Ecto.UUID.generate())

    conn =
      build_conn(:get, "/newsletters/unsubscribe")
      |> UnsubscribeController.unsubscribe(%{"token" => token})

    assert conn.status == 302
    assert conn.assigns[:flash]["error"] =~ "Invalid or expired"
  end

  test "POST /newsletters/unsubscribe (scope=list, the retired scope value) redirects with an error flash" do
    token = sign_legacy_list_token(Ecto.UUID.generate(), Ecto.UUID.generate())

    conn =
      build_conn(:post, "/newsletters/unsubscribe")
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "list"})

    assert conn.status == 302
    assert conn.assigns[:flash]["error"]
    refute conn.assigns[:flash]["info"]
  end

  test "POST /newsletters/unsubscribe (scope=all) does not absorb it — error flash, not a false success" do
    token = sign_legacy_list_token(Ecto.UUID.generate(), Ecto.UUID.generate())

    conn =
      build_conn(:post, "/newsletters/unsubscribe")
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "all"})

    assert conn.status == 302
    assert conn.assigns[:flash]["error"]
    refute conn.assigns[:flash]["info"]
  end

  test "POST /newsletters/unsubscribe/one-click still returns a blank 200 (RFC 8058 contract) without crashing" do
    token = sign_legacy_list_token(Ecto.UUID.generate(), Ecto.UUID.generate())

    conn =
      build_conn(:post, "/newsletters/unsubscribe/one-click")
      |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "GET /newsletters/unsubscribe/one-click redirects to the interactive page without crashing" do
    token = sign_legacy_list_token(Ecto.UUID.generate(), Ecto.UUID.generate())

    conn =
      build_conn(:get, "/newsletters/unsubscribe/one-click")
      |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    assert location =~ "/newsletters/unsubscribe"
  end
end
