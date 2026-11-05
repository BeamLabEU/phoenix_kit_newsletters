defmodule PhoenixKit.Newsletters.Web.BroadcastDetailsTest do
  @moduledoc """
  Direct callback-invocation unit tests for the `BroadcastDetails` LiveView —
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
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Web.BroadcastDetails
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    Newsletters.enable_system()
    enable_crm()
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
    broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])

    {:noreply, updated} =
      BroadcastDetails.handle_params(%{"id" => broadcast.uuid}, "/", socket_with_user(user))

    assert updated.assigns.tz == "3"
  end

  test "handle_params falls back to the system time_zone setting when no personal timezone is set" do
    Settings.update_setting("time_zone", "-5")
    user = %User{user_timezone: nil}
    broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])

    {:noreply, updated} =
      BroadcastDetails.handle_params(%{"id" => broadcast.uuid}, "/", socket_with_user(user))

    assert updated.assigns.tz == "-5"
  end

  test "handle_params falls back to UTC when there's no viewer at all" do
    broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])

    {:noreply, updated} =
      BroadcastDetails.handle_params(%{"id" => broadcast.uuid}, "/", socket())

    assert updated.assigns.tz == "0"
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
        phoenix_kit_current_scope: full_scope(),
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
      broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing", "Sales"])
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

  describe "retry send" do
    defp confirm_socket(broadcast) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(socket().assigns, %{
            broadcast_id: broadcast.uuid,
            page_param: nil,
            broadcast: broadcast,
            confirm_action: :retry_send,
            show_confirm_modal: true,
            flash: %{},
            __changed__: %{}
          })
      }
    end

    test "show_confirm arms the modal with the retry action" do
      {:noreply, updated} =
        BroadcastDetails.handle_event("show_confirm", %{"action" => "retry_send"}, socket())

      assert updated.assigns.confirm_action == :retry_send
      assert updated.assigns.show_confirm_modal
      assert updated.assigns.confirm_title == "Retry send"
    end

    test "a failed broadcast is sent again" do
      broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])
      {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: "failed"})

      {:noreply, updated} =
        BroadcastDetails.handle_event("confirm_action", %{}, confirm_socket(broadcast))

      refute updated.assigns.show_confirm_modal
      assert updated.assigns.broadcast.status == "sending"
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "sending"
    end

    # The button and Broadcaster.send/1's status guard both judge the copy
    # of the broadcast the page loaded, so the guard is only as good as the
    # re-read in front of it: without one, a click from a tab left open
    # since the broadcast moved on drags it back into "sending".
    test "a stale page cannot re-send a broadcast that has since moved past failed" do
      broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])
      {:ok, _} = Newsletters.update_broadcast(broadcast, %{status: "sent"})
      stale = %{broadcast | status: "failed"}

      {:noreply, updated} =
        BroadcastDetails.handle_event("confirm_action", %{}, confirm_socket(stale))

      assert updated.assigns.flash["error"] == "Cannot send a broadcast with status sent."
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "sent"
      # The refusal also refreshes the page off its stale copy.
      assert updated.assigns.broadcast.status == "sent"
    end
  end

  describe "cancelling" do
    defp cancel_socket(broadcast) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(socket().assigns, %{
            broadcast_id: broadcast.uuid,
            page_param: nil,
            broadcast: broadcast,
            confirm_action: :cancel_broadcast,
            show_confirm_modal: true,
            flash: %{},
            __changed__: %{}
          })
      }
    end

    defp confirm_cancel(broadcast) do
      {:noreply, updated} =
        BroadcastDetails.handle_event("confirm_action", %{}, cancel_socket(broadcast))

      updated
    end

    for status <- ~w(scheduled sending) do
      test "stops a #{status} broadcast" do
        broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])
        {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: unquote(status)})

        updated = confirm_cancel(broadcast)

        assert updated.assigns.flash["info"] =~ "cancelled"
        assert updated.assigns.broadcast.status == "cancelled"
        assert Newsletters.get_broadcast!(broadcast.uuid).status == "cancelled"
      end
    end

    test "a click that arrives after the send finished leaves it sent" do
      broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])
      {:ok, _} = Newsletters.update_broadcast(broadcast, %{status: "sent"})
      stale = %{broadcast | status: "sending"}

      updated = confirm_cancel(stale)

      assert updated.assigns.flash["error"] =~ "cannot be cancelled"
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "sent"
      # The refusal also refreshes the page off its stale copy.
      assert updated.assigns.broadcast.status == "sent"
    end
  end

  describe "recipient_display/1" do
    test "shows the address a managed organization's mail goes to, not its login" do
      organization = %User{
        email: "org-1@organization.invalid",
        managed_by_members: true,
        contact_email: "office@example.com"
      }

      assert BroadcastDetails.recipient_display(%{user: organization}) == "office@example.com"
    end

    test "falls back to the login when there is no address to show" do
      organization = %User{email: "org-1@organization.invalid", managed_by_members: true}

      assert BroadcastDetails.recipient_display(%{user: organization}) ==
               "org-1@organization.invalid"
    end
  end

  describe "the deliveries list" do
    defp with_deliveries(count) do
      broadcast = create_user_group_broadcast([Ecto.UUID.generate()], ["Marketing"])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..count do
          %{
            uuid: UUIDv7.generate(),
            broadcast_uuid: broadcast.uuid,
            recipient_email: "reader-#{n}@example.com",
            status: "pending",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Delivery, rows)
      broadcast
    end

    defp at_page(broadcast, params) do
      {:noreply, updated} =
        BroadcastDetails.handle_params(Map.put(params, "id", broadcast.uuid), "/", socket())

      updated
    end

    test "shows a page at a time, and knows how many there are" do
      broadcast = with_deliveries(51)

      first = at_page(broadcast, %{})
      assert length(first.assigns.deliveries) == 50
      assert first.assigns.total_count == 51
      assert first.assigns.total_pages == 2

      second = at_page(broadcast, %{"page" => "2"})
      assert length(second.assigns.deliveries) == 1
      assert second.assigns.page == 2
    end

    test "a page past the end lands on the last one" do
      broadcast = with_deliveries(51)

      assert %{page: 2, deliveries: [_one]} = at_page(broadcast, %{"page" => "9"}).assigns
    end

    test "an id that is not a uuid is reported, not crashed on" do
      {:noreply, updated} =
        BroadcastDetails.handle_params(
          %{"id" => "garbage"},
          "/",
          %{socket() | assigns: Map.put(socket().assigns, :flash, %{})}
        )

      assert updated.assigns.flash["error"] =~ "not found"
    end
  end
end
