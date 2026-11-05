defmodule PhoenixKit.Newsletters.BroadcastSendSafetyTest do
  @moduledoc """
  What must hold around the start of a send.

  A broadcast's status and its deliveries appear together or not at all, and
  every status decision is made on the row, never on the struct a caller holds.
  The sweep marks a `sending` broadcast with nothing pending as `sent`, so a
  `sending` row without its deliveries is a broadcast lost with nobody mailed.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  @moduletag :requires_v158

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitNewsletters.Test.Repo

  defp role_with_users(count) do
    {:ok, role} = Roles.create_role(%{name: "Audience #{System.unique_integer([:positive])}"})

    for _ <- 1..count//1 do
      {:ok, user} =
        %User{}
        |> User.guest_user_changeset(%{
          email: "reader-#{System.unique_integer([:positive])}@example.com"
        })
        |> Repo.insert()

      {:ok, _assignment} = Roles.assign_role(user, role.name)
    end

    role
  end

  defp create_broadcast(role, attrs \\ %{}) do
    base = %{
      subject: "Hello",
      source_type: "user_group",
      source_params: %{"role_uuids" => [role.uuid], "role_names_snapshot" => [role.name]},
      markdown_body: "Hello **reader**"
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  defp deliveries_of(broadcast) do
    Repo.aggregate(from(d in Delivery, where: d.broadcast_uuid == ^broadcast.uuid), :count)
  end

  defp start_oban do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
  end

  describe "the flip to sending and the deliveries are one transaction" do
    test "a crash while enqueueing leaves the broadcast as it was, ready to try again" do
      broadcast = role_with_users(2) |> create_broadcast()

      # No Oban instance is running, so the enqueue raises part way through.
      assert_raise RuntimeError, fn -> Broadcaster.send(broadcast) end

      assert %Broadcast{status: "draft", sent_at: nil, html_body: nil, total_recipients: 0} =
               Newsletters.get_broadcast!(broadcast.uuid)

      assert deliveries_of(broadcast) == 0

      start_oban()

      assert {:ok, %Broadcast{status: "sending", total_recipients: 2}} =
               Broadcaster.send(broadcast)

      assert deliveries_of(broadcast) == 2
    end

    test "the sweep cannot finish a send that has just started" do
      start_oban()
      broadcast = role_with_users(2) |> create_broadcast()

      assert {:ok, _sending} = Broadcaster.send(broadcast)

      assert Newsletters.repair_stuck_sending_broadcasts() == 0
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "sending"
    end

    test "total_recipients is right as soon as the send is visible" do
      start_oban()
      broadcast = role_with_users(3) |> create_broadcast()

      assert {:ok, %Broadcast{total_recipients: 3}} = Broadcaster.send(broadcast)
      assert Newsletters.get_broadcast!(broadcast.uuid).total_recipients == 3
    end

    test "the body sent is the row's, not the struct's" do
      start_oban()
      broadcast = role_with_users(1) |> create_broadcast()

      Repo.update_all(from(b in Broadcast, where: b.uuid == ^broadcast.uuid),
        set: [markdown_body: "Newer"]
      )

      assert {:ok, %Broadcast{html_body: html}} = Broadcaster.send(broadcast)
      assert html =~ "Newer"
    end
  end

  describe "the status is judged on the row" do
    for status <- ~w(sending sent cancelled) do
      test "a stale struct cannot start a broadcast that is #{status}" do
        broadcast = role_with_users(1) |> create_broadcast()
        {:ok, _moved_on} = Newsletters.update_broadcast(broadcast, %{status: unquote(status)})

        assert {:error, {:invalid_status, unquote(status)}} = Broadcaster.send(broadcast)

        assert %Broadcast{status: unquote(status), sent_at: nil} =
                 Newsletters.get_broadcast!(broadcast.uuid)

        assert deliveries_of(broadcast) == 0
      end
    end

    test "a broadcast deleted since it was read is reported, not crashed on" do
      broadcast = role_with_users(1) |> create_broadcast()
      {:ok, _deleted} = Newsletters.delete_broadcast(broadcast)

      assert {:error, :not_found} = Broadcaster.send(broadcast)
    end

    test "a row that no longer validates is refused and keeps its status" do
      broadcast = role_with_users(1) |> create_broadcast()

      Repo.update_all(from(b in Broadcast, where: b.uuid == ^broadcast.uuid),
        set: [source_params: %{}]
      )

      assert {:error, %Ecto.Changeset{}} = Broadcaster.send(broadcast)
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "draft"
      assert deliveries_of(broadcast) == 0
    end
  end

  describe "the scheduled tick" do
    defp due(role, attrs) do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      create_broadcast(role, Map.merge(%{status: "scheduled", scheduled_at: past}, attrs))
    end

    test "a broadcast whose send raises does not stop the ones due after it" do
      earlier = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      # Has recipients, so with no Oban running its enqueue raises.
      raises = role_with_users(1) |> due(%{scheduled_at: earlier})
      # No recipients, so nothing is enqueued and it starts.
      fine = role_with_users(0) |> due(%{})

      assert {:ok, 1} = Newsletters.process_scheduled_broadcasts()

      assert Newsletters.get_broadcast!(raises.uuid).status == "scheduled"
      assert Newsletters.get_broadcast!(fine.uuid).status == "sending"
    end

    test "a cancel landing during the tick stands" do
      start_oban()
      broadcast = role_with_users(1) |> due(%{})

      {:ok, cancelled} = Newsletters.cancel_broadcast(broadcast)

      assert {:error, {:invalid_status, "cancelled"}} = Broadcaster.send(broadcast)
      assert cancelled.status == "cancelled"
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "cancelled"
    end
  end

  describe "the sweep and deliveries whose job is gone" do
    defp pending_delivery(broadcast, email) do
      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, recipient_email: email})
        |> Repo.insert()

      delivery
    end

    defp sending_broadcast do
      role_with_users(0) |> create_broadcast(%{status: "sending"})
    end

    test "a pending delivery with no job left is failed, and the broadcast finishes" do
      start_oban()
      broadcast = sending_broadcast()
      delivery = pending_delivery(broadcast, "lost@example.com")

      assert Newsletters.repair_stuck_sending_broadcasts() == 1

      assert %Delivery{status: "failed", error: error} = Repo.get(Delivery, delivery.uuid)
      assert error =~ "without a result"

      # Nothing bounced: a job that vanished is not a provider's refusal.
      assert %Broadcast{status: "sent", bounced_count: 0, sent_count: 0} =
               Newsletters.get_broadcast!(broadcast.uuid)
    end

    test "a delivery whose broadcast still has a job waiting is left alone" do
      start_oban()
      broadcast = sending_broadcast()
      delivery = pending_delivery(broadcast, "waiting@example.com")

      {:ok, _job} =
        %{delivery_uuid: delivery.uuid, broadcast_uuid: broadcast.uuid}
        |> DeliveryWorker.new(schedule_in: 3600)
        |> Oban.insert()

      assert Newsletters.repair_stuck_sending_broadcasts() == 0

      assert Repo.get(Delivery, delivery.uuid).status == "pending"
      assert Newsletters.get_broadcast!(broadcast.uuid).status == "sending"
    end

    test "another broadcast's job does not keep this one waiting" do
      start_oban()
      broadcast = sending_broadcast()
      other = sending_broadcast()
      delivery = pending_delivery(broadcast, "lost@example.com")
      other_delivery = pending_delivery(other, "waiting@example.com")

      {:ok, _job} =
        %{delivery_uuid: other_delivery.uuid, broadcast_uuid: other.uuid}
        |> DeliveryWorker.new(schedule_in: 3600)
        |> Oban.insert()

      assert Newsletters.repair_stuck_sending_broadcasts() == 1

      assert Repo.get(Delivery, delivery.uuid).status == "failed"
      assert Repo.get(Delivery, other_delivery.uuid).status == "pending"
    end

    test "a broadcast that was cancelled keeps its pending rows" do
      start_oban()
      broadcast = sending_broadcast()
      delivery = pending_delivery(broadcast, "stopped@example.com")
      {:ok, _cancelled} = Newsletters.cancel_broadcast(broadcast)

      assert Newsletters.repair_stuck_sending_broadcasts() == 0
      assert Repo.get(Delivery, delivery.uuid).status == "pending"
    end

    test "with no Oban on this node nothing can be told, so nothing is touched" do
      broadcast = sending_broadcast()
      delivery = pending_delivery(broadcast, "unknown@example.com")

      assert Newsletters.repair_stuck_sending_broadcasts() == 0
      assert Repo.get(Delivery, delivery.uuid).status == "pending"
    end
  end
end
