defmodule PhoenixKit.Newsletters.BroadcasterIdempotencyTest do
  @moduledoc """
  DB-level idempotency for `Broadcaster.send/1`'s enqueue path (S4-B): a
  re-enqueue of a broadcast that already has deliveries must not create a
  second row per recipient. Before this, `process_batch/5`'s `insert_all`
  had no `ON CONFLICT` clause at all — the V154 partial unique indexes are
  the actual guarantee (`insert_all` bypasses `Delivery.changeset/2`), and
  `on_conflict: :nothing` is the write-path half of that guarantee.

  A normal `send/1` call can't be issued twice for the same broadcast —
  it only accepts `"draft"`/`"scheduled"` status, and the first call
  flips it to `"sending"`. These tests reset the status back to
  `"draft"` between calls to exercise the retry/crash-recovery path an
  operator or a re-run Oban job would hit in practice, without needing
  to reach into `Broadcaster`'s private functions.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  defp create_user do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "idem-recipient-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    user
  end

  defp resend!(broadcast) do
    {:ok, reset} = Newsletters.update_broadcast(broadcast, %{status: "draft"})
    Broadcaster.send(reset)
  end

  describe "newsletters_list source" do
    setup do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})

      {:ok, list} =
        Newsletters.create_list(%{
          name: "Idempotency list",
          slug: "idempotency-list-#{System.unique_integer([:positive])}"
        })

      users = for _ <- 1..2, do: create_user()
      Enum.each(users, &Newsletters.subscribe_user(list.uuid, &1.uuid))

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Idempotency test",
          list_uuid: list.uuid,
          markdown_body: "Hello",
          html_body: "<p>Hello</p>",
          text_body: "Hello"
        })

      %{broadcast: broadcast, users: users}
    end

    test "re-sending creates no duplicate delivery rows", %{broadcast: broadcast} do
      assert {:ok, first} = Broadcaster.send(broadcast)
      assert first.total_recipients == 2
      assert length(Newsletters.list_deliveries(first.uuid)) == 2

      assert {:ok, second} = resend!(first)
      assert length(Newsletters.list_deliveries(second.uuid)) == 2
    end

    test "re-sending a fully-duplicate broadcast does not zero out total_recipients", %{
      broadcast: broadcast
    } do
      assert {:ok, first} = Broadcaster.send(broadcast)
      assert first.total_recipients == 2

      # Every recipient already has a delivery for this broadcast, so the
      # resend's insert_all deduplicates all of them (0 new rows this
      # round) — total_recipients must still reflect the broadcast's
      # actual delivery count (2), not this round's insert delta. Using
      # the delta here would show "Recipients: 0" on broadcast_details
      # while sent_count keeps climbing toward 2, and make any sent/total
      # ratio divide by zero.
      assert {:ok, second} = resend!(first)
      assert second.total_recipients == 2
      assert length(Newsletters.list_deliveries(second.uuid)) == 2
    end

    test "a mixed resend (one duplicate + one new member) gives the original N plus the new one",
         %{broadcast: broadcast, users: [existing_user, _]} do
      assert {:ok, first} = Broadcaster.send(broadcast)
      assert length(Newsletters.list_deliveries(first.uuid)) == 2

      new_user = create_user()
      {:ok, _} = Newsletters.subscribe_user(first.list_uuid, new_user.uuid)

      assert {:ok, second} = resend!(first)
      # 3 active members now; 2 are duplicates, 1 is new — total_recipients
      # is the actual row count (3), not just this round's insert (1).
      assert second.total_recipients == 3

      deliveries = Newsletters.list_deliveries(second.uuid)
      assert length(deliveries) == 3
      assert Enum.any?(deliveries, &(&1.user_uuid == new_user.uuid))
      assert Enum.any?(deliveries, &(&1.user_uuid == existing_user.uuid))
    end
  end

  describe "crm_list source" do
    setup do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})

      {:ok, list} = Lists.create_list(%{name: "Idempotency CRM list #{System.unique_integer()}"})

      contacts =
        for _ <- 1..2 do
          {:ok, contact} =
            Contacts.create_contact(%{
              name: "Contact",
              email: "idem-contact-#{System.unique_integer([:positive])}@example.com"
            })

          {:ok, _member} = Lists.add_contact_to_list(contact, list, source: "manual")
          contact
        end

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Idempotency CRM test",
          source_type: "crm_list",
          crm_list_uuid: list.uuid,
          markdown_body: "Hello",
          html_body: "<p>Hello</p>",
          text_body: "Hello"
        })

      %{broadcast: broadcast, contacts: contacts}
    end

    test "re-sending creates no duplicate delivery rows and keeps total_recipients accurate", %{
      broadcast: broadcast
    } do
      assert {:ok, first} = Broadcaster.send(broadcast)
      assert first.total_recipients == 2
      assert length(Newsletters.list_deliveries(first.uuid)) == 2

      assert {:ok, second} = resend!(first)
      assert length(Newsletters.list_deliveries(second.uuid)) == 2
      assert second.total_recipients == 2
    end
  end
end
