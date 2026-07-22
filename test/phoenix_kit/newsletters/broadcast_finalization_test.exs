defmodule PhoenixKit.Newsletters.BroadcastFinalizationTest do
  @moduledoc """
  A broadcast stuck in "sending" forever: DeliveryWorker's per-delivery
  status transition never itself checked whether the broadcast was
  actually done. Covers the fix — the last delivery to leave Delivery's
  only non-terminal status ("pending") flips the broadcast's `status` from
  "sending" to "sent" atomically, computed from the deliveries themselves
  rather than from sent_count/bounced_count — and
  `Newsletters.repair_stuck_sending_broadcasts/0`'s sweep for broadcasts
  that got stuck before the fix existed.

  Counting from deliveries (not counters) matters because "blocked"
  (suppression-list hit) and permanent-failure statuses ("deleted",
  "not_configured", etc., all recorded as "failed" via
  `record_permanent_failure/3`) deliberately never bump sent_count or
  bounced_count — a counter-based predicate is unreachable the moment one
  recipient lands in either state.

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

  defp create_broadcast(attrs) do
    base = %{
      subject: "Hello",
      source_type: "user_group",
      source_params: %{"role_uuids" => [Ecto.UUID.generate()], "role_names_snapshot" => []},
      html_body: "<p>Body</p>",
      text_body: "Body",
      status: "sending"
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  # `status` defaults to "pending" (the schema default) — pass an already
  # -terminal status to seed a delivery that's not itself under test, e.g.
  # a co-recipient who already finished sending.
  defp create_delivery(broadcast, user, status \\ "pending") do
    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{
        broadcast_uuid: broadcast.uuid,
        user_uuid: user.uuid,
        status: status
      })
      |> Repo.insert()

    delivery
  end

  describe "the last worker finalizes the broadcast" do
    test "the last pending delivery reaching sent flips sending -> sent" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 1})
      create_delivery(broadcast, create_user(), "sent")
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

    test "the last pending delivery reaching a terminal bounce also finalizes" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 0})
      create_delivery(broadcast, create_user(), "sent")
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

    test "a blocked (suppression-list) delivery, uncounted, still finalizes when it's the last one" do
      broadcast = create_broadcast(%{total_recipients: 3, sent_count: 2, bounced_count: 0})
      create_delivery(broadcast, create_user(), "sent")
      create_delivery(broadcast, create_user(), "sent")
      delivery = create_delivery(broadcast, create_user())

      # Mirrors what record_permanent_failure/3 does for a {:blocked, _}
      # reason: same call, no counter_field.
      assert {:ok, _} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "blocked",
                 %{error: "suppressed"},
                 broadcast.uuid,
                 nil
               )

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sent"
      assert reloaded.sent_count == 2
      assert reloaded.bounced_count == 0
      assert Repo.get!(Delivery, delivery.uuid).status == "blocked"
    end

    test "a permanently-failed (misconfigured profile) delivery, uncounted, still finalizes" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 0})
      create_delivery(broadcast, create_user(), "sent")
      delivery = create_delivery(broadcast, create_user())

      # Mirrors record_permanent_failure/3 for a :deleted/:not_configured
      # reason — same call, status "failed", no counter_field.
      assert {:ok, _} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "failed",
                 %{error: ":not_configured"},
                 broadcast.uuid,
                 nil
               )

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sent"
      assert reloaded.bounced_count == 0
    end
  end

  describe "a non-final worker does not finalize" do
    test "other deliveries still pending leaves status sending" do
      broadcast = create_broadcast(%{total_recipients: 3, sent_count: 0})
      delivery = create_delivery(broadcast, create_user())
      create_delivery(broadcast, create_user())
      create_delivery(broadcast, create_user())

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

    test "a still-retryable transient failure on the last delivery does not finalize" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 1})
      create_delivery(broadcast, create_user(), "sent")
      delivery = create_delivery(broadcast, create_user())

      # Mirrors what DeliveryWorker.handle_failure/4 does on a non-terminal
      # attempt (attempt < max_attempts): Oban will still retry this job,
      # so the broadcast must not be reported "sent" — and, concretely,
      # must not lose its "Cancel broadcast" button (gated on status ==
      # "sending" in broadcast_details.html.heex) — while a send is still
      # queued to run.
      DeliveryWorker.handle_failure(delivery.uuid, broadcast.uuid, "timeout", false)

      reloaded = Repo.get!(Broadcast, broadcast.uuid)
      assert reloaded.status == "sending"
      assert reloaded.bounced_count == 0
    end
  end

  describe "repair_stuck_sending_broadcasts/0" do
    test "flips an already-stuck broadcast whose deliveries are all terminal" do
      stuck = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 1})
      create_delivery(stuck, create_user(), "sent")
      create_delivery(stuck, create_user(), "failed")

      still_in_flight = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 0})
      create_delivery(still_in_flight, create_user(), "sent")
      create_delivery(still_in_flight, create_user())

      assert Newsletters.repair_stuck_sending_broadcasts() == 1

      assert Repo.get!(Broadcast, stuck.uuid).status == "sent"
      assert Repo.get!(Broadcast, still_in_flight.uuid).status == "sending"
    end

    test "repairs a stuck broadcast whose only remaining delivery is blocked (counters alone never satisfy)" do
      stuck = create_broadcast(%{total_recipients: 2, sent_count: 1, bounced_count: 0})
      create_delivery(stuck, create_user(), "sent")
      create_delivery(stuck, create_user(), "blocked")

      assert Newsletters.repair_stuck_sending_broadcasts() == 1
      assert Repo.get!(Broadcast, stuck.uuid).status == "sent"
    end

    test "a second sweep with nothing left to repair is a no-op" do
      broadcast = create_broadcast(%{total_recipients: 1, sent_count: 1})
      create_delivery(broadcast, create_user(), "sent")

      assert Newsletters.repair_stuck_sending_broadcasts() == 1
      assert Newsletters.repair_stuck_sending_broadcasts() == 0
    end
  end

  describe "concurrent last-two-workers race" do
    test "two workers finishing at once still land on sent exactly once, no corruption" do
      broadcast = create_broadcast(%{total_recipients: 2, sent_count: 0})
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
      assert reloaded.sent_count == 2
    end
  end
end
