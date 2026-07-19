defmodule PhoenixKit.Newsletters.BroadcastFinalizationTest do
  @moduledoc """
  A broadcast stuck in "sending" forever: DeliveryWorker's per-delivery
  counter increment (`update_delivery_result/5`) never itself checked
  whether the broadcast was actually done. Covers the fix — the last
  worker to land flips `status` from "sending" to "sent" atomically —
  and `Newsletters.repair_stuck_sending_broadcasts/0`'s sweep for
  broadcasts that got stuck before the fix existed.

  `async: false`: the race test spawns real concurrent `Task`s sharing
  the sandboxed connection (`Sandbox.start_owner!/2` only puts the
  sandbox in `shared` mode for sync tests — see `DataCase`).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.Repo

  defp create_user do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "recipient-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    user
  end

  defp create_list do
    {:ok, list} =
      Newsletters.create_list(%{
        name: "Test list",
        slug: "test-list-#{System.unique_integer([:positive])}"
      })

    list
  end

  defp create_broadcast(attrs) do
    list = create_list()

    base = %{
      subject: "Hello",
      list_uuid: list.uuid,
      html_body: "<p>Body</p>",
      text_body: "Body",
      status: "sending"
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  defp create_delivery(broadcast, user) do
    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, user_uuid: user.uuid})
      |> Repo.insert()

    delivery
  end

  describe "the last worker finalizes the broadcast" do
    test "sent_count + bounced_count reaching total_recipients flips sending -> sent" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 1})
      delivery = create_delivery(broadcast, create_user())

      assert {:ok, _} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "sent",
                 %{sent_at: DateTime.utc_now()},
                 broadcast.uuid,
                 :sent_count
               )

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sent"
      assert reloaded.sent_count == 2
    end

    test "a mix of sent + bounced reaching the total also finalizes" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 0})
      delivery = create_delivery(broadcast, create_user())

      assert {:ok, _} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "failed",
                 %{error: "bounced"},
                 broadcast.uuid,
                 :bounced_count
               )

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sent"
      assert reloaded.bounced_count == 1
    end
  end

  describe "a non-final worker does not finalize" do
    test "sent_count + bounced_count still short of total_recipients leaves status sending" do
      broadcast = create_broadcast(%{total_recipients: 3, sent_count: 0})
      delivery = create_delivery(broadcast, create_user())

      assert {:ok, _} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "sent",
                 %{sent_at: DateTime.utc_now()},
                 broadcast.uuid,
                 :sent_count
               )

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sending"
      assert reloaded.sent_count == 1
    end
  end

  describe "repair_stuck_sending_broadcasts/0" do
    test "flips an already-stuck broadcast whose deliveries are all accounted for" do
      stuck =
        create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 1})

      still_in_flight = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 0})

      assert Newsletters.repair_stuck_sending_broadcasts() == 1

      assert Repo.get!(Broadcast, stuck.uuid).status == "sent"
      assert Repo.get!(Broadcast, still_in_flight.uuid).status == "sending"
    end

    test "a second sweep with nothing left to repair is a no-op" do
      create_broadcast(%{total_recipients: 1, sent_count: 1})

      assert Newsletters.repair_stuck_sending_broadcasts() == 1
      assert Newsletters.repair_stuck_sending_broadcasts() == 0
    end
  end

  describe "concurrent last-two-workers race" do
    test "two workers finishing at once still land on sent exactly once, no corruption" do
      broadcast = create_broadcast(%{total_recipients: 3, sent_count: 1})
      delivery_a = create_delivery(broadcast, create_user())
      delivery_b = create_delivery(broadcast, create_user())

      task_a =
        Task.async(fn ->
          DeliveryWorker.update_delivery_result(
            delivery_a,
            "sent",
            %{sent_at: DateTime.utc_now()},
            broadcast.uuid,
            :sent_count
          )
        end)

      task_b =
        Task.async(fn ->
          DeliveryWorker.update_delivery_result(
            delivery_b,
            "sent",
            %{sent_at: DateTime.utc_now()},
            broadcast.uuid,
            :sent_count
          )
        end)

      assert {:ok, _} = Task.await(task_a)
      assert {:ok, _} = Task.await(task_b)

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sent"
      assert reloaded.sent_count == 3
    end
  end
end
