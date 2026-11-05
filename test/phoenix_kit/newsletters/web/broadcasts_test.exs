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
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User

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
      Broadcasts.handle_params(%{}, "/admin/newsletters/broadcasts", socket_with_user(user))

    assert socket.assigns.tz == "3"
  end

  test "handle_params falls back to the system time_zone setting when no personal timezone is set" do
    Settings.update_setting("time_zone", "-5")
    user = %User{user_timezone: nil}

    {:noreply, socket} =
      Broadcasts.handle_params(%{}, "/admin/newsletters/broadcasts", socket_with_user(user))

    assert socket.assigns.tz == "-5"
  end

  test "handle_params falls back to UTC when there's no viewer at all" do
    {:noreply, socket} =
      Broadcasts.handle_params(
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
        Broadcasts.handle_params(
          params,
          "/admin/newsletters/broadcasts",
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
        )

      socket.assigns
    end

    test "older broadcasts are reachable past the first page" do
      create_broadcasts(51)

      assert %{broadcasts: first, total_count: 51, total_pages: 2} = at(%{})
      assert length(first) == 50

      assert %{broadcasts: [_oldest], page: 2} = at(%{"page" => "2"})
    end

    test "the count follows the status filter" do
      create_broadcasts(2)
      create_broadcasts(1, %{status: "sent"})

      assert %{total_count: 1, total_pages: 1, broadcasts: [_sent]} = at(%{"status" => "sent"})
    end
  end
end
