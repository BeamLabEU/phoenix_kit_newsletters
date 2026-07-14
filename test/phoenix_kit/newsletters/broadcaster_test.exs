defmodule PhoenixKit.Newsletters.BroadcasterTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Newsletters.SendProfile

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

  describe "send_interval_seconds/1" do
    test "no profile means no throttling — the pre-existing behavior" do
      assert Broadcaster.send_interval_seconds(nil) == 0
    end

    test "a profile with no limits set means no throttling" do
      assert Broadcaster.send_interval_seconds(%SendProfile{}) == 0
    end

    test "rate_per_hour spaces sends across the hour" do
      # 300/hour = one every 12 seconds. This is the shape of the profile
      # ("D5 Brevo fast/marketing") whose limit was stored and then ignored.
      assert Broadcaster.send_interval_seconds(%SendProfile{rate_per_hour: 300}) == 12
      assert Broadcaster.send_interval_seconds(%SendProfile{rate_per_hour: 20}) == 180
    end

    test "rate_per_day spaces sends across the day" do
      assert Broadcaster.send_interval_seconds(%SendProfile{rate_per_day: 100}) == 864
    end

    test "pause_seconds is a floor on the gap between sends" do
      assert Broadcaster.send_interval_seconds(%SendProfile{pause_seconds: 30}) == 30
    end

    test "the tightest of the three limits wins" do
      # Each limit is a ceiling the send must not exceed, so honoring only the
      # loosest would breach the others: 300/hour alone allows one per 12s, but
      # a 100/day cap does not.
      profile = %SendProfile{rate_per_hour: 300, rate_per_day: 100, pause_seconds: 30}
      assert Broadcaster.send_interval_seconds(profile) == 864

      profile = %SendProfile{rate_per_hour: 300, pause_seconds: 30}
      assert Broadcaster.send_interval_seconds(profile) == 30
    end

    test "a rate finer than one per second still yields a whole second" do
      # ceil/1, not floor: rounding down to 0 would silently disable the limit.
      assert Broadcaster.send_interval_seconds(%SendProfile{rate_per_hour: 7200}) == 1
    end

    test "zero reads as unset, not as 'never send'" do
      # Treating 0 as an infinitely long gap would strand a broadcast forever,
      # and it keeps the interval maths from dividing by zero.
      profile = %SendProfile{rate_per_hour: 0, rate_per_day: 0, pause_seconds: 0}
      assert Broadcaster.send_interval_seconds(profile) == 0
    end
  end
end
