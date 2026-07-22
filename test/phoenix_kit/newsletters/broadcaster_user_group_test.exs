defmodule PhoenixKit.Newsletters.BroadcasterUserGroupTest do
  @moduledoc """
  Exercises `Broadcaster.send/1`'s `user_group` branch, both against an
  empty role selection (proves the branch runs the full `do_send/1` path
  — status transition, total_recipients, the transaction-wrapped enqueue
  — without crashing) and against real core Roles/User fixtures (proves
  the created Delivery rows carry `user_uuid` + `recipient_email: nil`,
  and only for the actually-sendable members). Runs without the CRM
  module being installed at all for the recipients, unlike
  `BroadcasterCRMTest` — the whole point of `user_group` per the
  restructuring spec (§7): "user-group broadcasts work without the CRM
  module (soft-dep resolver, StaffLink pattern)".
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitNewsletters.Test.Repo

  defp create_user_group_broadcast(role_uuids) do
    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Role broadcast",
        source_type: "user_group",
        source_params: %{"role_uuids" => role_uuids, "role_names_snapshot" => []},
        markdown_body: "Hello",
        html_body: "<p>Hello</p>",
        text_body: "Hello"
      })

    broadcast
  end

  test "runs the full send path without crashing and resolves to zero recipients for an unknown role" do
    broadcast = create_user_group_broadcast([Ecto.UUID.generate()])

    assert {:ok, sent} = Broadcaster.send(broadcast)
    assert sent.status == "sending"
    assert sent.total_recipients == 0
    assert sent.crm_list_uuid == nil
  end

  describe "with real Roles/User fixtures" do
    setup do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})

      {:ok, role} = Roles.create_role(%{name: "Role#{System.unique_integer([:positive])}"})

      sendable =
        for _ <- 1..2 do
          {:ok, user} =
            %User{}
            |> User.guest_user_changeset(%{
              email: "sendable-#{System.unique_integer([:positive])}@example.com"
            })
            |> Repo.insert()

          {:ok, _assignment} = Roles.assign_role(user, role.name)
          user
        end

      {:ok, inactive_user} =
        %User{}
        |> User.guest_user_changeset(%{email: "inactive-#{System.unique_integer()}@example.com"})
        |> Repo.insert()

      {:ok, _assignment} = Roles.assign_role(inactive_user, role.name)
      {:ok, _} = Auth.update_user_status(inactive_user, %{"is_active" => false})

      %{role: role, sendable: sendable}
    end

    test "creates Delivery rows with user_uuid + recipient_email: nil for only the sendable members",
         %{role: role, sendable: sendable} do
      broadcast = create_user_group_broadcast([role.uuid])

      assert {:ok, sent} = Broadcaster.send(broadcast)
      assert sent.total_recipients == 2

      deliveries = Newsletters.list_deliveries(sent.uuid)
      assert length(deliveries) == 2

      assert Enum.all?(deliveries, &is_nil(&1.recipient_email))
      assert Enum.all?(deliveries, &(&1.status == "pending"))

      expected_users = sendable |> Enum.map(& &1.uuid) |> MapSet.new()
      actual_users = deliveries |> Enum.map(& &1.user_uuid) |> MapSet.new()
      assert actual_users == expected_users
    end
  end
end
