defmodule PhoenixKit.Newsletters.Web.UnsubscribeControllerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Web.UnsubscribeController

  describe "module structure" do
    test "UnsubscribeController module is loadable and exports expected functions" do
      assert Code.ensure_loaded?(UnsubscribeController)
      assert function_exported?(UnsubscribeController, :unsubscribe, 2)
      assert function_exported?(UnsubscribeController, :process_unsubscribe, 2)
      assert function_exported?(UnsubscribeController, :one_click_unsubscribe, 2)
    end
  end

  describe "process_unsubscribe/2 with missing token" do
    test "redirects to home when no token param is present" do
      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{})

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "/"
    end

    test "sets error flash when no token param is present" do
      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{})

      assert conn.assigns[:flash]["error"] =~ "Invalid or expired"
    end
  end

  defp build_conn(method, path) do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
  end

  describe "unsubscribe/2 with missing token" do
    test "redirects to home when no token param is present" do
      conn =
        build_conn(:get, "/newsletters/unsubscribe")
        |> UnsubscribeController.unsubscribe(%{})

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "/"
    end

    test "sets error flash when no token param is present" do
      conn =
        build_conn(:get, "/newsletters/unsubscribe")
        |> UnsubscribeController.unsubscribe(%{})

      assert conn.assigns[:flash]["error"] =~ "Invalid or expired"
    end
  end

  # Note: Tests for unsubscribe/2 with token, process_unsubscribe/2, and
  # one_click_unsubscribe/2 require a running PhoenixKitWeb.Endpoint (for
  # Phoenix.Token.verify) and, for one_click_unsubscribe/2, the dedicated
  # CSRF-exempt route wired in Web.Routes — these were verified live
  # against a running host app rather than here. That includes confirming
  # the one-click POST is actually reachable without a session/CSRF token
  # (unlike the shared /newsletters/unsubscribe POST, which stays behind
  # the host's normal :browser pipeline).
end
