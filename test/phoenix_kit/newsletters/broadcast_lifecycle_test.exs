defmodule PhoenixKit.Newsletters.BroadcastLifecycleTest do
  @moduledoc """
  The context functions that move a broadcast, which decide on the row as it is
  now rather than on the copy a page holds, and the counters a provider's events
  arrive through.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  @moduletag :requires_v158

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKitNewsletters.Test.Repo

  defp create_broadcast(attrs \\ %{}) do
    base = %{
      subject: "Hello",
      source_type: "user_group",
      source_params: %{"role_uuids" => [Ecto.UUID.generate()], "role_names_snapshot" => []}
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  describe "update_draft/2" do
    test "writes a draft" do
      broadcast = create_broadcast()

      assert {:ok, %Broadcast{subject: "Edited"}} =
               Newsletters.update_draft(broadcast, %{subject: "Edited"})
    end

    test "may move a draft on, as scheduling does" do
      broadcast = create_broadcast()

      assert {:ok, %Broadcast{status: "scheduled"}} =
               Newsletters.update_draft(broadcast, %{status: "scheduled"})
    end

    for status <- ~w(scheduled sending sent cancelled failed) do
      test "refuses a broadcast that is #{status} now, whatever the caller's copy says" do
        stale = create_broadcast()
        {:ok, _moved_on} = Newsletters.update_broadcast(stale, %{status: unquote(status)})

        assert {:error, {:invalid_status, unquote(status)}} =
                 Newsletters.update_draft(stale, %{subject: "EDITED", status: "draft"})

        assert %Broadcast{status: unquote(status), subject: "Hello"} =
                 Newsletters.get_broadcast!(stale.uuid)
      end
    end

    test "returns the changeset when the attrs do not validate" do
      assert {:error, %Ecto.Changeset{}} =
               Newsletters.update_draft(create_broadcast(), %{subject: ""})
    end

    test "reports a broadcast that is gone" do
      broadcast = create_broadcast()
      {:ok, _deleted} = Newsletters.delete_broadcast(broadcast)

      assert {:error, :not_found} = Newsletters.update_draft(broadcast, %{subject: "Edited"})
    end
  end

  describe "cancel_broadcast/1" do
    for status <- ~w(scheduled sending) do
      test "stops a #{status} broadcast" do
        broadcast = create_broadcast(%{status: unquote(status)})

        assert {:ok, %Broadcast{status: "cancelled"}} = Newsletters.cancel_broadcast(broadcast)
        assert Newsletters.get_broadcast!(broadcast.uuid).status == "cancelled"
      end
    end

    for status <- ~w(draft sent cancelled failed) do
      test "leaves a #{status} broadcast as it is, whatever the caller's copy says" do
        broadcast = create_broadcast(%{status: unquote(status)})
        stale = %{broadcast | status: "sending"}

        assert {:error, {:invalid_status, unquote(status)}} = Newsletters.cancel_broadcast(stale)
        assert Newsletters.get_broadcast!(broadcast.uuid).status == unquote(status)
      end
    end

    test "reports a broadcast that is gone" do
      broadcast = create_broadcast()
      {:ok, _deleted} = Newsletters.delete_broadcast(broadcast)

      assert {:error, :not_found} = Newsletters.cancel_broadcast(broadcast)
    end
  end

  describe "increment_broadcast_counter/2, as the emails package calls it" do
    test "is found the way that package looks for it" do
      assert function_exported?(Newsletters, :increment_broadcast_counter, 2)
    end

    for field <- [:delivered_count, :opened_count, :bounced_count] do
      test "adds one to #{field}" do
        broadcast = create_broadcast()

        assert :ok = Newsletters.increment_broadcast_counter(broadcast.uuid, unquote(field))
        assert :ok = Newsletters.increment_broadcast_counter(broadcast.uuid, unquote(field))

        assert Map.fetch!(Newsletters.get_broadcast!(broadcast.uuid), unquote(field)) == 2
      end
    end

    test "a broadcast that is gone is not an error" do
      assert :ok = Newsletters.increment_broadcast_counter(Ecto.UUID.generate(), :opened_count)
    end
  end

  describe "unschedule_broadcast/1" do
    test "takes a scheduled broadcast back to a draft, keeping its time" do
      at = ~U[2099-01-01 10:00:00Z]
      broadcast = create_broadcast(%{status: "scheduled", scheduled_at: at})

      assert {:ok, %Broadcast{status: "draft", scheduled_at: ^at}} =
               Newsletters.unschedule_broadcast(broadcast)

      assert Newsletters.get_broadcast!(broadcast.uuid).status == "draft"
    end

    for status <- ~w(draft sending sent cancelled failed) do
      test "leaves a #{status} broadcast as it is, whatever the page thinks" do
        broadcast = create_broadcast(%{status: unquote(status)})
        stale = %{broadcast | status: "scheduled"}

        assert {:error, {:invalid_status, unquote(status)}} =
                 Newsletters.unschedule_broadcast(stale)

        assert Newsletters.get_broadcast!(broadcast.uuid).status == unquote(status)
      end
    end

    test "a broadcast that is gone is refused" do
      assert {:error, :not_found} =
               Newsletters.unschedule_broadcast(%Broadcast{uuid: Ecto.UUID.generate()})
    end
  end

  describe "provider events, which arrive late and out of order" do
    defp delivery_at(broadcast, status) do
      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{
          broadcast_uuid: broadcast.uuid,
          recipient_email: "e#{System.unique_integer([:positive])}@example.com",
          status: status
        })
        |> Repo.insert()

      delivery
    end

    test "move a delivery forward" do
      delivery = delivery_at(create_broadcast(), "sent")

      {:ok, delivered} = Newsletters.update_delivery_status(delivery, "delivered")
      {:ok, opened} = Newsletters.update_delivery_status(delivered, "opened")
      {:ok, bounced} = Newsletters.update_delivery_status(opened, "bounced")

      assert bounced.status == "bounced"
    end

    test "a late Delivery does not take back an Open, and its time is still kept" do
      delivery = delivery_at(create_broadcast(), "opened")
      at = ~U[2026-01-01 10:00:00Z]

      {:ok, updated} =
        Newsletters.update_delivery_status(delivery, "delivered", %{delivered_at: at})

      assert %Delivery{status: "opened", delivered_at: ^at} = updated
    end

    test "an Open on mail that bounced leaves it bounced" do
      delivery = delivery_at(create_broadcast(), "bounced")

      assert {:ok, %Delivery{status: "bounced"}} =
               Newsletters.update_delivery_status(delivery, "opened")
    end

    test "the worker's own statuses are not held back" do
      delivery = delivery_at(create_broadcast(), "pending")

      assert {:ok, %Delivery{status: "failed"}} =
               Newsletters.update_delivery_status(delivery, "failed")
    end
  end

  describe "list order" do
    # A batch of 500 shares one timestamp, so the timestamp alone leaves the order
    # of a page undefined, and a recipient can repeat on one page and miss another.
    test "deliveries sharing a timestamp page without a repeat or a gap" do
      broadcast = create_broadcast()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..120 do
          %{
            uuid: UUIDv7.generate(),
            broadcast_uuid: broadcast.uuid,
            recipient_email: "row-#{n}@example.com",
            status: "pending",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Delivery, rows)

      paged =
        for offset <- [0, 50, 100] do
          broadcast.uuid
          |> Newsletters.list_deliveries(%{limit: 50, offset: offset})
          |> Enum.map(& &1.uuid)
        end

      assert paged |> List.flatten() |> Enum.sort() == rows |> Enum.map(& &1.uuid) |> Enum.sort()
      assert List.flatten(paged) == rows |> Enum.map(& &1.uuid) |> Enum.sort(:desc)
    end
  end

  describe "the module's declarations" do
    test "the queue is the worker's, so a host's tools can see it is missing" do
      assert [{queue, _options}] = Newsletters.oban_queues()

      assert to_string(queue) == DeliveryWorker.new(%{}).changes.queue
    end

    test "the public pages' segment is reserved" do
      assert Newsletters.reserved_route_prefixes() == ["newsletters"]
    end

    test "permission labels can be translated" do
      metadata = Newsletters.permission_metadata()

      assert metadata.gettext_backend == PhoenixKit.Newsletters.Gettext
    end
  end

  describe "the counts behind paging" do
    test "count_broadcasts/1 follows the status filter" do
      create_broadcast()
      create_broadcast(%{status: "sent"})

      assert Newsletters.count_broadcasts(%{status: "sent"}) == 1
      assert Newsletters.count_broadcasts(%{status: ""}) == 2
      assert Newsletters.count_broadcasts() == 2
    end

    test "count_deliveries/2 counts one broadcast's rows" do
      broadcast = create_broadcast()
      other = create_broadcast()

      for {owner, email} <- [{broadcast, "a@example.com"}, {other, "b@example.com"}] do
        {:ok, _delivery} =
          %Delivery{}
          |> Delivery.changeset(%{broadcast_uuid: owner.uuid, recipient_email: email})
          |> Repo.insert()
      end

      assert Newsletters.count_deliveries(broadcast.uuid) == 1
    end
  end
end
