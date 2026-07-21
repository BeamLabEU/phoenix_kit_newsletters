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

  test "mount resolves tz_offset from the viewer's profile timezone" do
    user = %User{user_timezone: "3"}

    {:ok, socket} = Broadcasts.mount(%{}, %{}, socket_with_user(user))

    assert socket.assigns.tz_offset == "3"
  end

  test "mount falls back to the system time_zone setting when no personal timezone is set" do
    Settings.update_setting("time_zone", "-5")
    user = %User{user_timezone: nil}

    {:ok, socket} = Broadcasts.mount(%{}, %{}, socket_with_user(user))

    assert socket.assigns.tz_offset == "-5"
  end

  test "mount falls back to UTC when there's no viewer at all" do
    {:ok, socket} =
      Broadcasts.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    assert socket.assigns.tz_offset == "0"
  end
end
