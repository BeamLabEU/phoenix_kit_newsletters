defmodule PhoenixKit.Newsletters.BroadcasterCRMTest do
  @moduledoc """
  Exercises `Broadcaster.send/1`'s `crm_list` branch, both against an
  unresolvable list (proves the branch runs the full `do_send/1` path —
  status transition, total_recipients, the transaction-wrapped enqueue —
  without crashing) and, since `phoenix_kit_crm` is a test-only dependency
  (see mix.exs), against real CRM fixtures (proves the created Delivery
  rows carry `recipient_email` + `user_uuid: nil`, and only for the
  actually-sendable members).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  defp create_crm_sourced_broadcast(crm_list_uuid) do
    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "CRM broadcast",
        source_type: "crm_list",
        crm_list_uuid: crm_list_uuid,
        markdown_body: "Hello",
        html_body: "<p>Hello</p>",
        text_body: "Hello"
      })

    broadcast
  end

  test "runs the full send path without crashing and resolves to zero recipients for an unknown list" do
    broadcast = create_crm_sourced_broadcast(Ecto.UUID.generate())

    assert {:ok, sent} = Broadcaster.send(broadcast)
    assert sent.status == "sending"
    assert sent.total_recipients == 0
    assert sent.list_uuid == nil
    assert sent.crm_list_uuid == broadcast.crm_list_uuid
  end

  describe "with real CRM fixtures" do
    setup do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})

      {:ok, list} = Lists.create_list(%{name: "Test List #{System.unique_integer([:positive])}"})

      sendable =
        for _ <- 1..2 do
          {:ok, contact} =
            Contacts.create_contact(%{
              name: "Contact",
              email: "sendable-#{System.unique_integer([:positive])}@example.com"
            })

          {:ok, _member} = Lists.add_contact_to_list(contact, list, source: "manual")
          contact
        end

      {:ok, opted_out_contact} =
        Contacts.create_contact(%{name: "Opted out", email: "opted-out@example.com"})

      {:ok, _member} = Lists.add_contact_to_list(opted_out_contact, list, source: "manual")
      {:ok, _} = Lists.opt_out(opted_out_contact)

      %{list: list, sendable: sendable}
    end

    test "creates Delivery rows with recipient_email + user_uuid: nil for only the sendable members",
         %{list: list, sendable: sendable} do
      broadcast = create_crm_sourced_broadcast(list.uuid)

      assert {:ok, sent} = Broadcaster.send(broadcast)
      assert sent.total_recipients == 2

      deliveries = Newsletters.list_deliveries(sent.uuid)
      assert length(deliveries) == 2

      assert Enum.all?(deliveries, &is_nil(&1.user_uuid))
      assert Enum.all?(deliveries, &(&1.status == "pending"))

      expected_emails = sendable |> Enum.map(& &1.email) |> MapSet.new()
      actual_emails = deliveries |> Enum.map(& &1.recipient_email) |> MapSet.new()
      assert actual_emails == expected_emails
    end
  end
end
