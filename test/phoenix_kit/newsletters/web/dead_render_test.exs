defmodule PhoenixKit.Newsletters.Web.DeadRenderTest do
  @moduledoc """
  First-load (dead) render of every admin LiveView, through a real request:
  `Phoenix.Router` → `Phoenix.LiveView.Plug` →
  `Phoenix.LiveView.Controller.live_render/3` → `Phoenix.Controller.render/3`.

  That last step is the one the callback-level tests (`mount/3` +
  `handle_params/3` on a hand-built socket) and `admin_render_test.exs`
  (`render/1` on the socket's assigns) never reach. A dead render merges the
  socket's assigns into the controller's render assigns, and `:layout` is a
  key `Phoenix.Controller` reads as the page layout — a LiveView that
  assigns its own `:layout` (the layout editor once did, for the layout
  record it edits) passes every other test and then raises a
  `CaseClauseError` on the first browser request.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Phoenix.ConnTest

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Layouts

  @endpoint PhoenixKitNewsletters.Test.DeadRenderEndpoint

  setup do
    Newsletters.enable_system()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  describe "layouts" do
    test "the list renders", %{conn: conn} do
      assert html_response(get(conn, "/layouts"), 200) =~ "layouts-status-filter"
    end

    test "the new-layout editor renders", %{conn: conn} do
      assert html_response(get(conn, "/layouts/new"), 200) =~ ~s(id="layout-form")
    end

    test "the edit-layout editor renders the layout being edited", %{conn: conn} do
      {:ok, layout} =
        Layouts.create_layout(%{
          "name" => "dead_render_layout",
          "html_body" => %{"en" => "<div>{{{content}}}</div>"}
        })

      html = html_response(get(conn, "/layouts/#{layout.uuid}/edit"), 200)

      assert html =~ ~s(id="layout-form")
      assert html =~ "dead_render_layout"
    end
  end

  # Broadcast rows need core V158 (the `attachments` column).
  describe "broadcasts" do
    @describetag :requires_v158

    setup do
      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Dead render",
          source_type: "user_group",
          source_params: %{"role_uuids" => [Ecto.UUID.generate()]}
        })

      {:ok, broadcast: broadcast}
    end

    test "the list renders", %{conn: conn} do
      assert html_response(get(conn, "/broadcasts"), 200) =~ "broadcasts-status-filter"
    end

    test "the new-broadcast editor renders", %{conn: conn} do
      assert html_response(get(conn, "/broadcasts/new"), 200)
    end

    test "the edit-broadcast editor renders", %{conn: conn, broadcast: broadcast} do
      assert html_response(get(conn, "/broadcasts/#{broadcast.uuid}/edit"), 200) =~
               "Dead render"
    end

    test "the details page renders", %{conn: conn, broadcast: broadcast} do
      assert html_response(get(conn, "/broadcasts/#{broadcast.uuid}"), 200) =~ "Dead render"
    end
  end

  describe "preference center" do
    test "an invalid token renders the invalid-token page", %{conn: conn} do
      conn = get(conn, "/newsletters/preferences", %{"token" => "bogus"})
      assert html_response(conn, 200)
    end

    test "without a token or a login it sends the visitor to log in", %{conn: conn} do
      assert redirected_to(get(conn, "/newsletters/preferences")) =~ "log-in"
    end
  end
end
