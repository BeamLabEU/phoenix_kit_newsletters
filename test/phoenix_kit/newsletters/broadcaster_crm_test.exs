defmodule PhoenixKit.Newsletters.BroadcasterCRMTest do
  @moduledoc """
  Exercises `Broadcaster.send/1`'s `crm_list` branch end-to-end. CRM
  itself isn't installed in this suite (see `CRMSourceTest`'s moduledoc),
  so this proves the branch runs the full do_send/1 path — status
  transition, total_recipients, the transaction-wrapped enqueue — without
  crashing, and degrades correctly to zero recipients. The actual
  resolver query against real CRM data (opted-out exclusion, no-email
  exclusion, dedup, preflight totals) was verified live via Tidewave.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcaster

  defp create_crm_sourced_broadcast do
    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "CRM broadcast",
        source_type: "crm_list",
        crm_list_uuid: Ecto.UUID.generate(),
        markdown_body: "Hello",
        html_body: "<p>Hello</p>",
        text_body: "Hello"
      })

    broadcast
  end

  test "runs the full send path without crashing and resolves to zero recipients" do
    broadcast = create_crm_sourced_broadcast()

    assert {:ok, sent} = Broadcaster.send(broadcast)
    assert sent.status == "sending"
    assert sent.total_recipients == 0
    assert sent.list_uuid == nil
    assert sent.crm_list_uuid == broadcast.crm_list_uuid
  end
end
