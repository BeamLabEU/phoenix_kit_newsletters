defmodule PhoenixKit.Newsletters.Web.BroadcastsTest do
  @moduledoc """
  Direct callback-invocation unit tests for the `Broadcasts` list LiveView —
  no connected LiveView process needed (see `BroadcastEditorTest`'s
  moduledoc for why: this package ships no real `PhoenixKitWeb.Endpoint`).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  # Every test here creates a real Broadcast row, and Broadcast.attachments
  # (core V158) is an unconditional schema field now — against a hex
  # phoenix_kit that doesn't ship V158 yet, that INSERT fails with
  # undefined_column. test_helper.exs excludes this tag (with an explicit
  # warning) when the column isn't present.
  @moduletag :requires_v158

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.Broadcasts
  alias PhoenixKit.Newsletters.Web.LayoutsIndex
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.UrlStateHarness

  setup do
    Newsletters.enable_system()
    :ok
  end

  defp socket_with_user(user) do
    %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: user, __changed__: %{}}}
  end

  # Timezone resolution happens in handle_params, not mount — mount runs
  # twice per connection (disconnected + connected render), which would
  # double the uncached DB read behind a viewer with no personal timezone
  # set. See BroadcastEditor's assign_tz/1 for the same pattern.
  test "handle_params resolves tz from the viewer's profile timezone" do
    user = %User{user_timezone: "3"}

    {:noreply, socket} =
      UrlStateHarness.handle_params(
        Broadcasts,
        %{},
        "/admin/newsletters/broadcasts",
        socket_with_user(user)
      )

    assert socket.assigns.tz == "3"
  end

  test "handle_params falls back to the system time_zone setting when no personal timezone is set" do
    Settings.update_setting("time_zone", "-5")
    user = %User{user_timezone: nil}

    {:noreply, socket} =
      UrlStateHarness.handle_params(
        Broadcasts,
        %{},
        "/admin/newsletters/broadcasts",
        socket_with_user(user)
      )

    assert socket.assigns.tz == "-5"
  end

  test "handle_params falls back to UTC when there's no viewer at all" do
    {:noreply, socket} =
      UrlStateHarness.handle_params(
        Broadcasts,
        %{},
        "/admin/newsletters/broadcasts",
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    assert socket.assigns.tz == "0"
  end

  describe "paging" do
    defp create_broadcasts(count, attrs \\ %{}) do
      for n <- 1..count do
        {:ok, broadcast} =
          Newsletters.create_broadcast(
            Map.merge(
              %{
                subject: "Broadcast #{n}",
                source_type: "crm_list",
                crm_list_uuid: Ecto.UUID.generate()
              },
              attrs
            )
          )

        broadcast
      end
    end

    defp at(params) do
      {:noreply, socket} =
        UrlStateHarness.handle_params(
          Broadcasts,
          params,
          "/admin/newsletters/broadcasts",
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
        )

      socket.assigns
    end

    test "older broadcasts are reachable past the first page" do
      create_broadcasts(26)

      assert %{broadcasts: first, total_count: 26, total_pages: 2, per_page: 25} = at(%{})
      assert length(first) == 25

      assert %{broadcasts: [_oldest], page: 2} = at(%{"page" => "2"})
    end

    test "the page size comes from the URL, and only one the selector offers" do
      create_broadcasts(26)

      assert %{broadcasts: first, total_pages: 3, per_page: 10} = at(%{"per_page" => "10"})
      assert length(first) == 10
      assert %{per_page: 25} = at(%{"per_page" => "1000"})
    end

    test "a status that does not exist lists everything" do
      create_broadcasts(1)

      assert %{status_filter: "", total_count: 1} = at(%{"status" => "bogus"})
    end

    test "a page past the end replaces the address with the last page" do
      create_broadcasts(1)

      {:noreply, short} =
        UrlStateHarness.handle_params(
          Broadcasts,
          %{"page" => "9"},
          "/admin/newsletters/broadcasts",
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
        )

      assert short.assigns.page == 1
      assert {:live, :patch, %{to: dropped, kind: :replace}} = short.redirected
      assert URI.parse(dropped).path == "/admin/newsletters/broadcasts"
      refute dropped =~ "page="

      create_broadcasts(25)

      {:noreply, long} =
        UrlStateHarness.handle_params(
          Broadcasts,
          %{"page" => "9"},
          "/admin/newsletters/broadcasts",
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
        )

      assert long.assigns.page == 2
      assert {:live, :patch, %{to: kept, kind: :replace}} = long.redirected
      assert URI.parse(kept).path == "/admin/newsletters/broadcasts"
      assert URI.decode_query(URI.parse(kept).query)["page"] == "2"
    end

    test "a page the list has is left in the address" do
      create_broadcasts(26)

      {:noreply, socket} =
        UrlStateHarness.handle_params(
          Broadcasts,
          %{"page" => "2"},
          "/admin/newsletters/broadcasts",
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
        )

      assert socket.assigns.page == 2
      assert socket.redirected == nil
    end

    test "the count follows the status filter" do
      create_broadcasts(2)
      create_broadcasts(1, %{status: "sent"})

      assert %{total_count: 1, total_pages: 1, broadcasts: [_sent]} = at(%{"status" => "sent"})
    end
  end

  # A crafted `status[]=` used to raise in URI encoding and take the page down.
  test "a status filter that is not a string is ignored" do
    socket =
      UrlStateHarness.prepare(Broadcasts, %{}, %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, url_path: "/admin/newsletters/broadcasts"}
      })

    assert {:noreply, %{redirected: nil}} =
             Broadcasts.handle_event("filter_status", %{"status" => ["sent"]}, socket)

    assert {:noreply, %{redirected: {:live, :patch, %{to: to}}}} =
             Broadcasts.handle_event("filter_status", %{"status" => "sent"}, socket)

    assert to =~ "status=sent"
  end

  test "the layouts filter ignores one that is not a string as well" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:noreply, %{redirected: nil}} =
             LayoutsIndex.handle_event(
               "filter_status",
               %{"status" => %{"a" => "b"}},
               socket
             )
  end

  test "the layouts filter drops a status that does not exist, and keeps one that does" do
    socket =
      UrlStateHarness.prepare(LayoutsIndex, %{}, %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, url_path: "/admin/newsletters/layouts"}
      })

    assert {:noreply, %{redirected: {:live, :patch, %{to: dropped}}}} =
             LayoutsIndex.handle_event("filter_status", %{"status" => "nope"}, socket)

    refute dropped =~ "status="

    assert {:noreply, %{redirected: {:live, :patch, %{to: archived}}}} =
             LayoutsIndex.handle_event("filter_status", %{"status" => "archived"}, socket)

    assert archived =~ "status=archived"
  end
end
