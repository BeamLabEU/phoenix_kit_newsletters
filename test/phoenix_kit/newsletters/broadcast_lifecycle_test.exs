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
