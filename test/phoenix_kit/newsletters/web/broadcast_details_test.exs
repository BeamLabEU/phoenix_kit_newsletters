defmodule PhoenixKit.Newsletters.Web.BroadcastDetailsTest do
  @moduledoc """
  Direct callback-invocation unit tests for the `BroadcastDetails` LiveView —
  no connected LiveView process needed (see `BroadcastEditorTest`'s
  moduledoc for why: this package ships no real `PhoenixKitWeb.Endpoint`).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.BroadcastDetails
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles

  setup do
    Newsletters.enable_system()
    :ok
  end

  defp socket_with_user(user) do
    %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: user, __changed__: %{}}}
  end

  test "mount resolves tz_offset from the viewer's profile timezone" do
    user = %User{user_timezone: "3"}

    {:ok, socket} = BroadcastDetails.mount(%{}, %{}, socket_with_user(user))

    assert socket.assigns.tz_offset == "3"
  end

  test "mount falls back to the system time_zone setting when no personal timezone is set" do
    Settings.update_setting("time_zone", "-5")
    user = %User{user_timezone: nil}

    {:ok, socket} = BroadcastDetails.mount(%{}, %{}, socket_with_user(user))

    assert socket.assigns.tz_offset == "-5"
  end

  test "mount falls back to UTC when there's no viewer at all" do
    {:ok, socket} =
      BroadcastDetails.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    assert socket.assigns.tz_offset == "0"
  end

  # ── Task #48: recipient-source display (user_group) ──
  # Merged from the #48 branch: the "List" card and the stale-roles
  # warning for source_type = "user_group" broadcasts, exercised via
  # the same direct-callback pattern as the timezone tests above.

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        broadcast_id: nil,
        loading: true,
        broadcast: nil,
        deliveries: [],
        delivery_stats: %{},
        crm_list: nil,
        crm_preflight: nil,
        user_group_preflight: nil,
        page_title: "",
        __changed__: %{}
      }
    }
  end

  defp create_role(name) do
    {:ok, role} = Roles.create_role(%{name: name})
    role
  end

  defp create_user_group_broadcast(role_uuids, role_names) do
    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "user_group broadcast check",
        html_body: "<p>Hi</p>",
        source_type: "user_group",
        source_params: %{"role_uuids" => role_uuids, "role_names_snapshot" => role_names}
      })

    broadcast
  end

  defp load(broadcast_uuid) do
    {:noreply, updated} =
      BroadcastDetails.handle_params(%{"id" => broadcast_uuid}, "/", socket())

    updated
  end

  describe "role_names_snapshot/1" do
    test "delegates to Broadcast.role_names_snapshot/1" do
      broadcast = create_user_group_broadcast(["some-uuid"], ["Marketing", "Sales"])
      assert BroadcastDetails.role_names_snapshot(broadcast) == ["Marketing", "Sales"]
    end
  end

  describe "handle_params/3 — user_group_preflight" do
    test "is computed for a user_group broadcast, reflecting live role membership" do
      role = create_role("Marketing")
      broadcast = create_user_group_broadcast([role.uuid], ["Marketing"])

      updated = load(broadcast.uuid)

      assert %{stale_roles: 0} = updated.assigns.user_group_preflight
    end

    test "flags a stale_roles count > 0 when a targeted role was deleted after the broadcast was saved" do
      role = create_role("Temp Role")
      broadcast = create_user_group_broadcast([role.uuid], ["Temp Role"])

      {:ok, _} = Roles.delete_role(role)

      updated = load(broadcast.uuid)

      assert %{stale_roles: 1} = updated.assigns.user_group_preflight
    end

    test "is nil for a crm_list broadcast" do
      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "crm_list broadcast check",
          html_body: "<p>Hi</p>",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate()
        })

      updated = load(broadcast.uuid)

      assert updated.assigns.user_group_preflight == nil
    end

    # The "nil for a newsletters_list broadcast" variant was removed with
    # the source itself (S4-E part 2) — the crm_list case above still
    # pins the "nil for non-user_group sources" behavior.
  end
end
