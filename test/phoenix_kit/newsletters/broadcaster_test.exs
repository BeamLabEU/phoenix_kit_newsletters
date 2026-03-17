defmodule PhoenixKit.Newsletters.BroadcasterTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Broadcaster

  describe "module structure" do
    test "Broadcaster module is loadable and exports send/1" do
      assert Code.ensure_loaded?(Broadcaster)
      assert function_exported?(Broadcaster, :send, 1)
    end
  end

  describe "send/1 guards" do
    test "rejects broadcast with invalid status" do
      broadcast = %Broadcast{
        uuid: "test-uuid",
        status: "sent",
        list_uuid: "list-uuid",
        markdown_body: "Hello"
      }

      assert {:error, {:invalid_status, "sent"}} = Broadcaster.send(broadcast)
    end

    test "rejects broadcast with 'sending' status" do
      broadcast = %Broadcast{
        uuid: "test-uuid",
        status: "sending",
        list_uuid: "list-uuid",
        markdown_body: "Hello"
      }

      assert {:error, {:invalid_status, "sending"}} = Broadcaster.send(broadcast)
    end
  end
end
