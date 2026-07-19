defmodule PhoenixKit.Newsletters.ProcessScheduledBroadcastsTest do
  @moduledoc """
  Regression test for `Newsletters.process_scheduled_broadcasts/0`: a
  scheduled broadcast targeting an archived CRM list used to retry
  forever (status stayed "scheduled", so every tick re-fetched it and
  logged the same `{:crm_list_not_active, _}` failure). It must instead
  fail terminally on the first tick and be left alone afterwards.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    :ok
  end

  test "a scheduled broadcast against an archived CRM list fails terminally instead of retrying forever" do
    {:ok, list} =
      Lists.create_list(%{name: "Archived before send #{System.unique_integer([:positive])}"})

    {:ok, _list} = Lists.archive_list(list)

    past =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:second)

    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Scheduled to an archived list",
        source_type: "crm_list",
        crm_list_uuid: list.uuid,
        status: "scheduled",
        scheduled_at: past,
        markdown_body: "Hello",
        html_body: "<p>Hello</p>",
        text_body: "Hello"
      })

    assert {:ok, 0} = Newsletters.process_scheduled_broadcasts()

    failed = Newsletters.get_broadcast!(broadcast.uuid)
    assert failed.status == "failed"

    # Second tick: the "status == scheduled" query no longer matches this
    # broadcast, so it isn't reprocessed.
    assert {:ok, 0} = Newsletters.process_scheduled_broadcasts()

    unchanged = Newsletters.get_broadcast!(broadcast.uuid)
    assert unchanged.status == "failed"
    assert unchanged.updated_at == failed.updated_at
  end
end
