defmodule PhoenixKit.Newsletters.Web.PermissionsTest do
  @moduledoc """
  `newsletters.send`, `newsletters.audiences` and the CRM gate, driven by
  direct callback calls (this package has no LiveView endpoint). Each write
  is a crafted event the page would not offer to the scope under test, so
  removing any one check fails a test here.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  @moduletag :requires_v158

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.{Delivery, PermissionBackfill}
  alias PhoenixKit.Newsletters.Web.{BroadcastDetails, BroadcastEditor, Verification}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    Newsletters.enable_system()
    enable_crm()
    :ok
  end

  defp socket(scope, extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            phoenix_kit_current_user: nil,
            phoenix_kit_current_scope: scope
          },
          extra
        )
    }
  end

  defp mounted_editor(scope) do
    {:ok, socket} = BroadcastEditor.mount(%{}, %{}, socket(scope, %{live_action: :new}))
    {:noreply, socket} = BroadcastEditor.handle_params(%{}, "/", socket)
    socket
  end

  defp error_flash(socket), do: socket.assigns.flash["error"]
  defp broadcast_count, do: length(Newsletters.list_broadcasts())

  defp role_params do
    {:ok, role} = Roles.create_role(%{name: "NRole#{System.unique_integer([:positive])}"})
    %{"subject" => "Hello", "source_type" => "user_group", "role_uuids" => [role.uuid]}
  end

  describe "BroadcastEditor: newsletters.send" do
    test "send_now and schedule are refused without it, before anything is saved" do
      socket = mounted_editor(scope_with(["newsletters"]))
      refute socket.assigns.can_send
      before = broadcast_count()

      {:noreply, s} =
        BroadcastEditor.handle_event(
          "submit",
          Map.put(role_params(), "action", "send_now"),
          socket
        )

      assert error_flash(s) =~ "permission to send"

      {:noreply, s} =
        BroadcastEditor.handle_event(
          "submit",
          role_params()
          |> Map.put("action", "schedule")
          |> Map.put("scheduled_at", "2099-01-01T10:00"),
          socket
        )

      assert error_flash(s) =~ "permission to send"
      assert broadcast_count() == before
    end

    test "the base key may still save a draft" do
      socket = mounted_editor(scope_with(["newsletters"]))
      before = broadcast_count()

      {:noreply, _} = BroadcastEditor.handle_event("submit", role_params(), socket)
      assert broadcast_count() == before + 1
    end

    test "a newsletters.send holder may schedule" do
      socket = mounted_editor(scope_with(["newsletters", "newsletters.send"]))
      assert socket.assigns.can_send

      {:noreply, _} =
        BroadcastEditor.handle_event(
          "submit",
          role_params()
          |> Map.put("action", "schedule")
          |> Map.put("scheduled_at", "2099-01-01T10:00"),
          socket
        )

      assert Enum.any?(Newsletters.list_broadcasts(), &(&1.status == "scheduled"))
    end
  end

  describe "BroadcastEditor: CRM lists need the crm key" do
    setup do
      {:ok, list} =
        Lists.create_list(%{
          name: "NList #{System.unique_integer([:positive])}",
          subscribable: true
        })

      {:ok, list: list}
    end

    test "without crm no list is offered and a crafted CRM-list save is refused", %{list: list} do
      socket = mounted_editor(scope_with(["newsletters", "newsletters.send"]))

      refute socket.assigns.crm_available
      assert socket.assigns.crm_lists == []
      assert socket.assigns.source_type == "user_group"

      before = broadcast_count()

      {:noreply, s} =
        BroadcastEditor.handle_event(
          "submit",
          %{"subject" => "Hi", "source_type" => "crm_list", "crm_list_uuid" => list.uuid},
          socket
        )

      assert error_flash(s) =~ "CRM lists"
      assert broadcast_count() == before
    end

    test "with crm the list is offered and saved", %{list: list} do
      socket = mounted_editor(scope_with(["newsletters", "crm"]))

      assert socket.assigns.crm_available
      assert Enum.any?(socket.assigns.crm_lists, &(&1.uuid == list.uuid))

      {:noreply, _} =
        BroadcastEditor.handle_event(
          "submit",
          %{"subject" => "Hi", "source_type" => "crm_list", "crm_list_uuid" => list.uuid},
          socket
        )

      assert Enum.any?(Newsletters.list_broadcasts(), &(&1.crm_list_uuid == list.uuid))
    end
  end

  describe "BroadcastDetails" do
    defp broadcast_with_delivery do
      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Sent",
          html_body: "<p>Hi</p>",
          source_type: "user_group",
          source_params: %{"role_uuids" => [Ecto.UUID.generate()]}
        })

      {:ok, user} =
        %User{}
        |> User.guest_user_changeset(%{
          email: "rcpt-#{System.unique_integer([:positive])}@example.com"
        })
        |> Repo.insert()

      {:ok, _} =
        %Delivery{}
        |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, user_uuid: user.uuid})
        |> Repo.insert()

      broadcast
    end

    defp details(scope, broadcast) do
      {:ok, socket} = BroadcastDetails.mount(%{}, %{}, socket(scope))
      {:noreply, socket} = BroadcastDetails.handle_params(%{"id" => broadcast.uuid}, "/", socket)
      socket
    end

    test "recipient deliveries are loaded only with newsletters.audiences" do
      broadcast = broadcast_with_delivery()

      assert details(scope_with(["newsletters"]), broadcast).assigns.deliveries == []

      assert [_] =
               details(scope_with(["newsletters", "newsletters.audiences"]), broadcast).assigns.deliveries
    end

    test "cancelling a sending broadcast needs newsletters.send" do
      broadcast = broadcast_with_delivery()
      {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: "sending"})

      refused =
        scope_with(["newsletters"])
        |> details(broadcast)
        |> Phoenix.Component.assign(:confirm_action, :cancel_broadcast)

      {:noreply, s} = BroadcastDetails.handle_event("confirm_action", %{}, refused)
      assert error_flash(s) =~ "permission to send"
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "sending"

      allowed =
        scope_with(["newsletters", "newsletters.send"])
        |> details(broadcast)
        |> Phoenix.Component.assign(:confirm_action, :cancel_broadcast)

      {:noreply, _} = BroadcastDetails.handle_event("confirm_action", %{}, allowed)
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "cancelled"
    end

    test "retrying a failed send needs newsletters.send" do
      broadcast = broadcast_with_delivery()
      {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: "failed"})

      socket =
        scope_with(["newsletters"])
        |> details(broadcast)
        |> Phoenix.Component.assign(:confirm_action, :retry_send)

      {:noreply, s} = BroadcastDetails.handle_event("confirm_action", %{}, socket)

      assert error_flash(s) =~ "permission to send"
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "failed"
    end
  end

  describe "Verification: newsletters.audiences" do
    test "mount redirects away without it" do
      {:ok, s} = Verification.mount(%{}, %{}, socket(scope_with(["newsletters"])))
      assert s.redirected
    end

    test "a crafted event is refused without it" do
      {:noreply, s} =
        Verification.handle_event(
          "select_audience",
          %{"source" => "user_group"},
          socket(scope_with(["newsletters"]))
        )

      assert error_flash(s) =~ "permission"
      refute s.redirected
    end

    test "CRM lists are offered only with the crm key" do
      {:ok, s} =
        Verification.mount(%{}, %{}, socket(scope_with(["newsletters", "newsletters.audiences"])))

      refute s.redirected
      refute s.assigns.crm_available

      {:ok, s} = Verification.mount(%{}, %{}, socket(full_scope()))
      assert s.assigns.crm_available
    end
  end

  describe "migrate_legacy/0 backfill" do
    defp role_with(keys) do
      {:ok, role} = Roles.create_role(%{name: "BRole#{System.unique_integer([:positive])}"})
      for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key, nil)
      role
    end

    defp keys(role), do: Permissions.get_permissions_for_role(role.uuid)

    test "grants both keys once to roles holding newsletters, and sets each flag" do
      holder = role_with(["newsletters"])
      outsider = role_with([])

      assert :ok = Newsletters.migrate_legacy()

      for key <- ~w(newsletters.send newsletters.audiences) do
        assert key in keys(holder)
        refute key in keys(outsider)
      end

      assert Settings.get_setting("newsletters_send_backfilled") == "true"
      assert Settings.get_setting("newsletters_audiences_backfilled") == "true"

      late = role_with(["newsletters"])
      assert :ok = Newsletters.migrate_legacy()
      assert keys(late) == ["newsletters"]
    end

    test "a failed grant leaves the flag unset, so the next boot retries" do
      holder = role_with(["newsletters"])
      failing = fn _role, _key, _by -> {:error, :boom} end

      assert {:error, _} =
               PermissionBackfill.run(
                 "newsletters",
                 "newsletters.send",
                 "newsletters_send_backfilled",
                 failing
               )

      refute Settings.get_setting("newsletters_send_backfilled") == "true"
      refute "newsletters.send" in keys(holder)

      assert :ok =
               PermissionBackfill.run(
                 "newsletters",
                 "newsletters.send",
                 "newsletters_send_backfilled"
               )

      assert "newsletters.send" in keys(holder)
    end
  end
end
