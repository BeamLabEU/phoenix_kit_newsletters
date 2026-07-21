defmodule PhoenixKit.Newsletters.BroadcasterInactiveUserTest do
  @moduledoc """
  Aligns the newsletters_list send path with `UserGroupSource.sendable?/1`,
  which already excludes a deactivated (`is_active: false`) user —
  external review on PR#22 flagged the two flavors silently disagreeing:
  a deactivated user who's still an "active" `ListMember` used to receive
  the newsletters_list broadcast while being dropped from the user_group
  one. Separate commit from the unsubscribe-token fix on purpose, so the
  behavior change is visible on its own.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    :ok
  end

  defp create_user(attrs \\ %{}) do
    base = %{email: "inactive-check-#{System.unique_integer([:positive])}@example.com"}

    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(Map.merge(base, attrs))
      |> Repo.insert()

    user
  end

  test "a deactivated user is excluded from a newsletters_list send, even with an active ListMember row" do
    {:ok, list} =
      Newsletters.create_list(%{
        name: "Inactive check list",
        slug: "inactive-check-list-#{System.unique_integer([:positive])}"
      })

    active_user = create_user()
    inactive_user = create_user()

    {:ok, _} = Newsletters.subscribe_user(list.uuid, active_user.uuid)
    {:ok, _} = Newsletters.subscribe_user(list.uuid, inactive_user.uuid)
    {:ok, _} = Auth.update_user_status(inactive_user, %{"is_active" => false})

    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Inactive user check",
        list_uuid: list.uuid,
        markdown_body: "Hello",
        html_body: "<p>Hello</p>",
        text_body: "Hello"
      })

    assert {:ok, sent} = Broadcaster.send(broadcast)

    deliveries = Newsletters.list_deliveries(sent.uuid)
    delivered_user_uuids = Enum.map(deliveries, & &1.user_uuid)

    assert active_user.uuid in delivered_user_uuids
    refute inactive_user.uuid in delivered_user_uuids
    assert sent.total_recipients == 1
  end
end
