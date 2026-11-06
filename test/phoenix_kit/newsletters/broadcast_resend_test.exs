defmodule PhoenixKit.Newsletters.BroadcastResendTest do
  @moduledoc """
  Sending a finished broadcast again to the deliveries that failed.

  Mail cannot be retracted, so who is left out matters most: a resend reaches
  only deliveries known not to have reached a provider. It also returns a `sent`
  broadcast to `sending`, which the sweep would finish on the spot if the reopened
  rows were not there, so the same one-transaction rule as a first send applies.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  @moduletag :requires_v158

  import Ecto.Query, only: [from: 2]
  import Swoosh.TestAssertions

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitCRM.Lists, as: CRMLists
  alias PhoenixKitNewsletters.Test.Repo

  setup :set_swoosh_global

  defp start_oban do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
  end

  defp role_with_users(count) do
    {:ok, role} = Roles.create_role(%{name: "Audience #{System.unique_integer([:positive])}"})

    users =
      for _ <- 1..count//1 do
        {:ok, user} =
          %User{}
          |> User.guest_user_changeset(%{
            email: "reader-#{System.unique_integer([:positive])}@example.com"
          })
          |> Repo.insert()

        {:ok, _assignment} = Roles.assign_role(user, role.name)
        user
      end

    {role, users}
  end

  defp create_broadcast(role, attrs) do
    base = %{
      subject: "Hello",
      source_type: "user_group",
      source_params: %{"role_uuids" => [role.uuid], "role_names_snapshot" => [role.name]},
      markdown_body: "Hello **reader**",
      html_body: "<p>Hello <strong>reader</strong></p>",
      text_body: "Hello reader"
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  defp sent_broadcast(attrs \\ %{}) do
    {role, _users} = role_with_users(0)
    create_broadcast(role, Map.merge(%{status: "sent"}, attrs))
  end

  defp delivery(broadcast, attrs \\ %{}) do
    base = %{
      broadcast_uuid: broadcast.uuid,
      recipient_email: "row-#{System.unique_integer([:positive])}@example.com"
    }

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    delivery
  end

  defp failed(broadcast, attrs \\ %{}) do
    delivery(broadcast, Map.merge(%{status: "failed", error: ":not_configured"}, attrs))
  end

  # A role recipient's row, which the worker can actually send.
  defp failed_for(broadcast, user) do
    failed(broadcast, %{user_uuid: user.uuid, recipient_email: nil})
  end

  defp reload(%Broadcast{uuid: uuid}), do: Newsletters.get_broadcast!(uuid)
  defp reload(%Delivery{uuid: uuid}), do: Repo.get(Delivery, uuid)

  defp jobs_of(broadcast) do
    Repo.all(
      from(j in Oban.Job, where: fragment("?->>'broadcast_uuid' = ?", j.args, ^broadcast.uuid))
    )
  end

  defp delivery_uuids_in_jobs(broadcast) do
    broadcast |> jobs_of() |> Enum.map(& &1.args["delivery_uuid"]) |> Enum.sort()
  end

  defp statuses_of(broadcast) do
    Repo.all(
      from(d in Delivery,
        where: d.broadcast_uuid == ^broadcast.uuid,
        select: d.status,
        order_by: d.status
      )
    )
  end

  defp drain do
    Oban.drain_queue(queue: :newsletters_delivery, with_scheduled: true)
  end

  # Every mail captured so far, however many, whatever order the jobs ran in.
  defp mailed do
    receive do
      {:email, email} -> [email | mailed()]
    after
      0 -> []
    end
  end

  defp addresses(emails) do
    emails |> Enum.flat_map(& &1.to) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
  end

  # An SMTP connection nobody filled in: every send through it is refused, which
  # is the permanent failure a real bad connection produces.
  defp dead_profile(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("smtp", "dead #{unique}")

    {:ok, profile} =
      SendProfiles.create_send_profile(
        Map.merge(
          %{name: "Profile #{unique}", integration_uuid: integration_uuid, provider_kind: "smtp"},
          attrs
        )
      )

    profile
  end

  describe "who goes out again" do
    test "only failed deliveries, and each gets one job" do
      start_oban()
      broadcast = sent_broadcast()

      first = failed(broadcast)
      second = failed(broadcast, %{error: ~s({:smtp, "421 try later"})})

      others =
        for status <- ~w(sent delivered opened bounced blocked) do
          delivery(broadcast, %{status: status})
        end

      assert {:ok, %Broadcast{status: "sending"}, 2} = Broadcaster.resend_failed(broadcast)

      assert %Delivery{status: "pending", error: nil} = reload(first)
      assert %Delivery{status: "pending", error: nil} = reload(second)
      assert delivery_uuids_in_jobs(broadcast) == Enum.sort([first.uuid, second.uuid])

      for delivery <- others do
        assert reload(delivery).status == delivery.status
      end
    end

    test "a delivery the sweep settled stays failed, because its mail may have gone out" do
      start_oban()
      broadcast = sent_broadcast(%{status: "sending"})
      orphan = delivery(broadcast)

      assert Newsletters.repair_stuck_sending_broadcasts() == 1
      assert %Delivery{status: "failed"} = reload(orphan)
      assert Newsletters.count_resendable_deliveries(broadcast.uuid) == 0

      assert {:error, :nothing_to_resend} = Broadcaster.resend_failed(reload(broadcast))
      assert jobs_of(broadcast) == []
    end

    test "the sweep's rows are left out without holding back the rest" do
      start_oban()
      broadcast = sent_broadcast()
      unknown = failed(broadcast, %{error: Delivery.no_result_error()})
      known = failed(broadcast)

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)

      assert reload(known).status == "pending"
      assert %Delivery{status: "failed", error: error} = reload(unknown)
      assert error == Delivery.no_result_error()
    end

    test "a delivery a provider accepted stays failed, whatever was written to it later" do
      start_oban()
      broadcast = sent_broadcast()

      accepted =
        failed(broadcast, %{sent_at: UtilsDate.utc_now(), error: "rejected after acceptance"})

      assert {:error, :nothing_to_resend} = Broadcaster.resend_failed(broadcast)
      assert reload(accepted).status == "failed"
    end

    test "a failed delivery with no error text still counts" do
      start_oban()
      broadcast = sent_broadcast()
      silent = failed(broadcast, %{error: nil})

      assert Newsletters.count_resendable_deliveries(broadcast.uuid) == 1
      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)
      assert reload(silent).status == "pending"
    end

    test "another broadcast's failed deliveries are untouched" do
      start_oban()
      broadcast = sent_broadcast()
      other = sent_broadcast()
      failed(broadcast)
      theirs = failed(other)

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)

      assert reload(theirs).status == "failed"
      assert reload(other).status == "sent"
    end
  end

  describe "the reopening is one transaction" do
    test "a crash while enqueueing leaves everything as it was, ready to try again" do
      broadcast = sent_broadcast()
      row = failed(broadcast)

      # No Oban instance is running, so the enqueue raises part way through.
      assert_raise RuntimeError, fn -> Broadcaster.resend_failed(broadcast) end

      assert reload(broadcast).status == "sent"
      assert %Delivery{status: "failed", error: ":not_configured"} = reload(row)

      start_oban()

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)
    end

    test "the sweep can neither finish a resend nor fail its deliveries" do
      start_oban()
      broadcast = sent_broadcast()
      row = failed(broadcast)

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)

      assert Newsletters.repair_stuck_sending_broadcasts() == 0
      assert reload(broadcast).status == "sending"
      assert reload(row).status == "pending"
    end

    test "the send profile's pace holds across batches" do
      start_oban()
      profile = dead_profile(%{pause_seconds: 60})
      broadcast = sent_broadcast(%{send_profile_uuid: profile.uuid})
      now = UtilsDate.utc_now()

      rows =
        for _ <- 1..501 do
          %{
            uuid: UUIDv7.generate(),
            broadcast_uuid: broadcast.uuid,
            recipient_email: "row-#{System.unique_integer([:positive])}@example.com",
            status: "failed",
            error: ":deleted",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Delivery, rows)

      assert {:ok, _sending, 501} = Broadcaster.resend_failed(broadcast)

      times =
        broadcast |> jobs_of() |> Enum.map(&DateTime.to_unix(&1.scheduled_at)) |> Enum.sort()

      assert length(Enum.uniq(times)) == 501
      assert_in_delta List.last(times) - hd(times), 500 * 60, 5
    end
  end

  describe "the status is judged on the row" do
    for status <- ~w(draft scheduled sending cancelled failed) do
      test "a broadcast that is #{status} is refused, whatever the page thinks" do
        start_oban()
        broadcast = sent_broadcast(%{status: unquote(status)})
        row = failed(broadcast)
        stale = %{broadcast | status: "sent"}

        assert {:error, {:invalid_status, unquote(status)}} = Broadcaster.resend_failed(stale)

        assert reload(broadcast).status == unquote(status)
        assert reload(row).status == "failed"
        assert jobs_of(broadcast) == []
      end
    end

    test "a second resend cannot queue the same deliveries twice" do
      start_oban()
      broadcast = sent_broadcast()
      row = failed(broadcast)

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)
      assert {:error, {:invalid_status, "sending"}} = Broadcaster.resend_failed(broadcast)

      assert delivery_uuids_in_jobs(broadcast) == [row.uuid]
    end

    test "with nothing to resend the broadcast stays as it is" do
      start_oban()
      broadcast = sent_broadcast()
      delivery(broadcast, %{status: "sent"})

      assert {:error, :nothing_to_resend} = Broadcaster.resend_failed(broadcast)
      assert reload(broadcast).status == "sent"
    end

    test "a broadcast that is gone is refused" do
      assert {:error, :not_found} =
               Broadcaster.resend_failed(%Broadcast{
                 uuid: UUIDv7.generate(),
                 source_type: "user_group"
               })
    end

    test "an archived CRM list never receives anything" do
      start_oban()
      {:ok, list} = CRMLists.create_list(%{name: "Old #{System.unique_integer([:positive])}"})
      {:ok, _archived} = CRMLists.archive_list(list)

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Hello",
          source_type: "crm_list",
          crm_list_uuid: list.uuid,
          status: "sent"
        })

      row = failed(broadcast)

      assert {:error, {:crm_list_not_active, "archived"}} = Broadcaster.resend_failed(broadcast)

      assert reload(broadcast).status == "sent"
      assert reload(row).status == "failed"
    end
  end

  describe "what the first send leaves in place" do
    test "the body and the send time stay, whatever was edited since" do
      start_oban()
      sent_at = ~U[2026-01-02 03:04:05Z]
      broadcast = sent_broadcast(%{sent_at: sent_at, total_recipients: 2})
      failed(broadcast)
      delivery(broadcast, %{status: "sent"})

      Repo.update_all(from(b in Broadcast, where: b.uuid == ^broadcast.uuid),
        set: [markdown_body: "Edited since"]
      )

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)

      assert %Broadcast{sent_at: ^sent_at, total_recipients: 2, html_body: html} =
               reload(broadcast)

      assert html == broadcast.html_body
    end
  end

  describe "bounced_count" do
    # Two deliveries that ran out of retries, through the worker's own path, next
    # to a real provider bounce recorded the way the emails package records it.
    defp exhausted_broadcast do
      broadcast = sent_broadcast(%{status: "sending"})
      rows = [delivery(broadcast), delivery(broadcast)]

      delivery(broadcast, %{status: "bounced", error: "Bounced"})
      Newsletters.increment_broadcast_counter(broadcast.uuid, :bounced_count)

      exhaust(broadcast, rows)
      {broadcast, rows}
    end

    defp exhaust(broadcast, rows) do
      for row <- rows do
        DeliveryWorker.handle_failure(row.uuid, broadcast.uuid, :timeout, true)
      end
    end

    test "gives back what the reopened deliveries were counted as" do
      start_oban()
      {broadcast, _rows} = exhausted_broadcast()

      assert %Broadcast{status: "sent", bounced_count: 3} = reload(broadcast)

      assert {:ok, %Broadcast{bounced_count: 1}, 2} =
               Broadcaster.resend_failed(reload(broadcast))

      assert reload(broadcast).bounced_count == 1
    end

    test "a delivery that fails again is counted once, not twice" do
      start_oban()
      {broadcast, rows} = exhausted_broadcast()

      assert {:ok, _sending, 2} = Broadcaster.resend_failed(reload(broadcast))
      exhaust(broadcast, rows)

      assert %Broadcast{status: "sent", bounced_count: 3} = reload(broadcast)
    end

    test "a connection failure was never a bounce, so nothing is taken back for it" do
      start_oban()
      broadcast = sent_broadcast(%{bounced_count: 1})
      delivery(broadcast, %{status: "bounced"})
      failed(broadcast)

      assert {:ok, %Broadcast{bounced_count: 1}, 1} = Broadcaster.resend_failed(broadcast)
    end
  end

  describe "from a bad connection to the mail arriving" do
    test "everyone it failed gets the broadcast once the connection is fixed" do
      start_oban()
      {role, users} = role_with_users(2)
      profile = dead_profile()
      broadcast = create_broadcast(role, %{send_profile_uuid: profile.uuid})

      assert {:ok, _sending} = Broadcaster.send(broadcast)
      drain()

      assert %Broadcast{status: "sent", sent_count: 0, bounced_count: 0} = reload(broadcast)
      assert statuses_of(broadcast) == ~w(failed failed)
      assert mailed() == []

      {:ok, _disabled} = SendProfiles.update_send_profile(profile, %{enabled: false})

      assert {:ok, %Broadcast{status: "sending"}, 2} =
               Broadcaster.resend_failed(reload(broadcast))

      drain()

      assert addresses(mailed()) == users |> Enum.map(& &1.email) |> Enum.sort()
      assert statuses_of(broadcast) == ~w(sent sent)
      assert %Broadcast{status: "sent", sent_count: 2, bounced_count: 0} = reload(broadcast)
    end

    test "a connection still broken costs only another try" do
      start_oban()
      {role, [user]} = role_with_users(1)
      profile = dead_profile()
      broadcast = create_broadcast(role, %{status: "sent", send_profile_uuid: profile.uuid})
      failed_for(broadcast, user)

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)
      drain()

      assert reload(broadcast).status == "sent"
      assert statuses_of(broadcast) == ~w(failed)
      assert Newsletters.count_resendable_deliveries(broadcast.uuid) == 1

      {:ok, _disabled} = SendProfiles.update_send_profile(profile, %{enabled: false})

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(reload(broadcast))
      drain()

      assert addresses(mailed()) == [user.email]
      assert statuses_of(broadcast) == ~w(sent)
    end

    test "someone already mailed is not mailed again" do
      start_oban()
      {role, [reached, missed]} = role_with_users(2)
      broadcast = create_broadcast(role, %{status: "sent"})

      delivery(broadcast, %{
        user_uuid: reached.uuid,
        recipient_email: nil,
        status: "sent",
        sent_at: UtilsDate.utc_now()
      })

      failed_for(broadcast, missed)

      assert {:ok, _sending, 1} = Broadcaster.resend_failed(broadcast)
      drain()

      assert addresses(mailed()) == [missed.email]
    end

    test "someone who has opted out since is blocked, and the broadcast still finishes" do
      start_oban()
      {role, [staying, leaving]} = role_with_users(2)
      broadcast = create_broadcast(role, %{status: "sent"})
      failed_for(broadcast, staying)
      gone = failed_for(broadcast, leaving)

      {:ok, _user} = UserGroupSource.record_opt_out(leaving)

      assert {:ok, _sending, 2} = Broadcaster.resend_failed(broadcast)
      drain()

      assert addresses(mailed()) == [staying.email]
      assert reload(gone).status == "blocked"
      assert reload(broadcast).status == "sent"
    end

    test "cancelling stops what is left of a resend, for good" do
      start_oban()
      {role, [user]} = role_with_users(1)
      broadcast = create_broadcast(role, %{status: "sent"})
      row = failed_for(broadcast, user)

      assert {:ok, sending, 1} = Broadcaster.resend_failed(broadcast)
      assert {:ok, _cancelled} = Newsletters.cancel_broadcast(sending)
      drain()

      assert mailed() == []
      assert reload(row).status == "pending"
      assert {:error, {:invalid_status, "cancelled"}} = Broadcaster.resend_failed(sending)
    end
  end
end
