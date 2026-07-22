defmodule PhoenixKit.Newsletters.Web.BroadcastsTest do
  @moduledoc """
  Direct callback-invocation unit tests for the `Broadcasts` list LiveView —
  no connected LiveView process needed (see `BroadcastEditorTest`'s
  moduledoc for why: this package ships no real `PhoenixKitWeb.Endpoint`).
  """

  use PhoenixKitNewsletters.DataCase, async: false

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
  test "handle_params resolves tz_offset from the viewer's profile timezone" do
    user = %User{user_timezone: "3"}

    {:noreply, socket} =
      Broadcasts.handle_params(%{}, "/admin/newsletters/broadcasts", socket_with_user(user))

    assert socket.assigns.tz_offset == "3"
  end

  test "handle_params falls back to the system time_zone setting when no personal timezone is set" do
    Settings.update_setting("time_zone", "-5")
    user = %User{user_timezone: nil}

    {:noreply, socket} =
      Broadcasts.handle_params(%{}, "/admin/newsletters/broadcasts", socket_with_user(user))

    assert socket.assigns.tz_offset == "-5"
  end

  test "handle_params falls back to UTC when there's no viewer at all" do
    {:noreply, socket} =
      Broadcasts.handle_params(
        %{},
        "/admin/newsletters/broadcasts",
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    assert socket.assigns.tz_offset == "0"
  end
end
