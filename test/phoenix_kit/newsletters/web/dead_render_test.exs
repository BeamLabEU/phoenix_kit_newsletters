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
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKitNewsletters.Test.Repo

  @endpoint PhoenixKitNewsletters.Test.DeadRenderEndpoint

  setup do
    Newsletters.enable_system()
    PhoenixKitNewsletters.TestScopes.enable_crm()
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

  describe "address verification" do
    @engine_key :email_verification_engine

    test "without an engine configured the page renders the explaining alert", %{conn: conn} do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)

      html = html_response(get(conn, "/verification"), 200)

      assert html =~ "Address verification"
      assert html =~ "verification-unavailable"
      refute html =~ "verification-audience-form"
    end

    test "with an engine configured the page renders the audience selector", %{conn: conn} do
      Application.put_env(
        :phoenix_kit_newsletters,
        @engine_key,
        PhoenixKitNewsletters.Test.FakeVerificationEngine
      )

      on_exit(fn -> Application.delete_env(:phoenix_kit_newsletters, @engine_key) end)

      html = html_response(get(conn, "/verification"), 200)

      assert html =~ "verification-audience-form"
      refute html =~ "verification-unavailable"
    end

    test "garbage query parameters still render", %{conn: conn} do
      conn = get(conn, "/verification", %{"source" => "x", "roles" => "nope", "page" => "-4"})
      assert html_response(conn, 200)
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
      location = redirected_to(get(conn, "/newsletters/preferences"))

      assert location =~ "/users/log-in"
      refute location =~ "/phoenix_kit/phoenix_kit"
    end
  end

  describe "broadcast actions and paging" do
    defp broadcast(attrs) do
      {:ok, broadcast} =
        Newsletters.create_broadcast(
          Map.merge(
            %{
              subject: "Rendered",
              source_type: "crm_list",
              crm_list_uuid: Ecto.UUID.generate()
            },
            attrs
          )
        )

      broadcast
    end

    test "a scheduled broadcast can be cancelled from its page", %{conn: conn} do
      scheduled = broadcast(%{status: "scheduled"})

      assert html_response(get(conn, "/broadcasts/#{scheduled.uuid}"), 200) =~ "Cancel broadcast"
    end

    test "a sent broadcast cannot", %{conn: conn} do
      sent = broadcast(%{status: "sent"})

      refute html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200) =~ "Cancel broadcast"
    end

    defp delivery(broadcast, attrs) do
      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(
          Map.merge(
            %{
              broadcast_uuid: broadcast.uuid,
              recipient_email: "r#{System.unique_integer([:positive])}@example.com"
            },
            attrs
          )
        )
        |> Repo.insert()

      delivery
    end

    test "a sent broadcast with failed deliveries offers to resend them", %{conn: conn} do
      sent = broadcast(%{status: "sent"})
      delivery(sent, %{status: "failed", error: ":not_configured"})

      html = html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200)

      assert html =~ "Resend failed deliveries"
      refute html =~ "may have gone out"
    end

    test "a sent broadcast with none does not", %{conn: conn} do
      sent = broadcast(%{status: "sent"})
      delivery(sent, %{status: "sent"})

      refute html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200) =~
               "Resend failed deliveries"
    end

    test "someone who cannot send is not offered it", %{conn: conn} do
      sent = broadcast(%{status: "sent"})
      delivery(sent, %{status: "failed", error: ":not_configured"})
      conn = init_test_session(conn, %{"test_permissions" => ["newsletters"]})

      refute html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200) =~
               "Resend failed deliveries"
    end

    test "a broadcast still sending does not, whatever has failed so far", %{conn: conn} do
      sending = broadcast(%{status: "sending"})
      delivery(sending, %{status: "failed", error: ":not_configured"})

      refute html_response(get(conn, "/broadcasts/#{sending.uuid}"), 200) =~
               "Resend failed deliveries"
    end

    test "says why a failed delivery cannot be resent", %{conn: conn} do
      sent = broadcast(%{status: "sent"})
      delivery(sent, %{status: "failed", error: Delivery.no_result_error()})

      html = html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200)

      assert html =~ "1 failed delivery may have gone out"
      refute html =~ "Resend failed deliveries"
    end

    test "a layout link is applied once, not twice", %{conn: conn} do
      html = html_response(get(conn, "/layouts"), 200)

      assert html =~ ~s(href="#{Paths.layout_new()}")
      refute html =~ "/phoenix_kit/phoenix_kit"
    end

    test "a scheduled broadcast can go back to being a draft", %{conn: conn} do
      scheduled = broadcast(%{status: "scheduled"})

      assert html_response(get(conn, "/broadcasts/#{scheduled.uuid}"), 200) =~ "Back to draft"
    end

    test "a sent one cannot", %{conn: conn} do
      sent = broadcast(%{status: "sent"})

      refute html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200) =~ "Back to draft"
    end

    test "someone who cannot send cannot move it back either", %{conn: conn} do
      scheduled = broadcast(%{status: "scheduled"})
      conn = init_test_session(conn, %{"test_permissions" => ["newsletters"]})

      refute html_response(get(conn, "/broadcasts/#{scheduled.uuid}"), 200) =~ "Back to draft"
    end

    test "the message can be read on the page, whatever became of the broadcast", %{conn: conn} do
      cancelled = broadcast(%{status: "cancelled", markdown_body: "The words themselves"})

      assert html_response(get(conn, "/broadcasts/#{cancelled.uuid}"), 200) =~
               "The words themselves"
    end

    test "Retry is not offered for an archived list, where it could only be refused",
         %{conn: conn} do
      {:ok, list} =
        PhoenixKitCRM.Lists.create_list(%{name: "Old #{System.unique_integer([:positive])}"})

      {:ok, _archived} = PhoenixKitCRM.Lists.archive_list(list)
      failed = broadcast(%{status: "failed", crm_list_uuid: list.uuid})

      refute html_response(get(conn, "/broadcasts/#{failed.uuid}"), 200) =~ "Retry send"
    end

    test "nor Resend, for the same reason", %{conn: conn} do
      {:ok, list} =
        PhoenixKitCRM.Lists.create_list(%{name: "Old #{System.unique_integer([:positive])}"})

      {:ok, _archived} = PhoenixKitCRM.Lists.archive_list(list)
      sent = broadcast(%{status: "sent", crm_list_uuid: list.uuid})
      delivery(sent, %{status: "failed", error: ":not_configured"})

      refute html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200) =~
               "Resend failed deliveries"
    end

    test "Retry is offered where it can work", %{conn: conn} do
      {:ok, list} =
        PhoenixKitCRM.Lists.create_list(%{name: "Live #{System.unique_integer([:positive])}"})

      failed = broadcast(%{status: "failed", crm_list_uuid: list.uuid})

      assert html_response(get(conn, "/broadcasts/#{failed.uuid}"), 200) =~ "Retry send"
    end

    test "a status that is not one reads as no filter", %{conn: conn} do
      for _ <- 1..51, do: broadcast(%{})

      # Given as params: this endpoint has no parser to read them from a query
      # string. A map raises when the page links are built.
      for status <- [%{"a" => "b"}, ["x"], "bogus"] do
        html = html_response(get(conn, "/broadcasts", %{"status" => status}), 200)

        assert html =~ "page=2"
        refute html =~ "status="
      end
    end

    test "the numbers are cumulative, as on the list", %{conn: conn} do
      sent = broadcast(%{status: "sent"})
      for status <- ~w(sent delivered delivered opened), do: delivery(sent, %{status: status})

      html = html_response(get(conn, "/broadcasts/#{sent.uuid}"), 200)

      # Four went out, three of them arrived, and one of those was opened.
      assert html =~ ~r{Sent</div>\s*<div[^>]*>\s*4\s*</div>}
      assert html =~ ~r{Delivered</div>\s*<div[^>]*>\s*3\s*</div>}
      assert html =~ ~r{Opened</div>\s*<div[^>]*>\s*1\s*</div>}
    end

    test "the list offers the next page", %{conn: conn} do
      for _ <- 1..51, do: broadcast(%{})

      html = html_response(get(conn, "/broadcasts"), 200)

      assert html =~ "page=2"
      assert html =~ "51"
    end
  end
end
