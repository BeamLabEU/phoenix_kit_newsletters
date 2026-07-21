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
  alias PhoenixKit.Users.Roles
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

  describe "user_group source" do
    setup do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})

      {:ok, role} = Roles.create_role(%{name: "Idempotency role #{System.unique_integer()}"})
      users = for _ <- 1..2, do: create_user()
      Enum.each(users, &Roles.assign_role(&1, role.name))

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Idempotency test",
          source_type: "user_group",
          source_params: %{"role_uuids" => [role.uuid], "role_names_snapshot" => [role.name]},
          markdown_body: "Hello",
          html_body: "<p>Hello</p>",
          text_body: "Hello"
        })

      %{broadcast: broadcast, role: role, users: users}
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

    test "a mixed resend (one duplicate + one new member) gives the original N plus the new one",
         %{broadcast: broadcast, role: role, users: [existing_user, _]} do
      assert {:ok, first} = Broadcaster.send(broadcast)
      assert length(Newsletters.list_deliveries(first.uuid)) == 2

      new_user = create_user()
      {:ok, _} = Roles.assign_role(new_user, role.name)

      assert {:ok, second} = resend!(first)
      # 3 role members now; 2 are duplicates, 1 is new — total_recipients
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
