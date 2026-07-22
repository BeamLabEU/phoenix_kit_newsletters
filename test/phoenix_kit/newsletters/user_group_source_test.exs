defmodule PhoenixKit.Newsletters.UserGroupSourceTest do
  @moduledoc """
  Exercises the resolver against real core Roles/User fixtures — Roles is
  a hard dependency of newsletters, so unlike `CRMSourceTest` this needs
  no `available?/0` gate. The CRM opt-out check is exercised too:
  `phoenix_kit_crm` is a test-only dependency (see mix.exs), so the
  "linked contact opted out" path is real, not simulated.

  Resolution is by role uuid (see `Broadcast.role_uuids/1`'s moduledoc
  for why names aren't used) — the rename/delete tests below are the
  reason that decision was made: a renamed role must not lose its
  audience, and a deleted (or simply stale/garbage) uuid must not crash
  the resolver, only shrink what it returns.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitCRM.Schemas.Contact
  alias PhoenixKitNewsletters.Test.Repo

  defp create_user(attrs \\ %{}) do
    base = %{email: "ug-user-#{System.unique_integer([:positive])}@example.com"}

    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(Map.merge(base, attrs))
      |> Repo.insert()

    user
  end

  defp create_role(name \\ nil) do
    name = name || "Role#{System.unique_integer([:positive])}"
    {:ok, role} = Roles.create_role(%{name: name})
    role
  end

  defp assign(user, role) do
    {:ok, _assignment} = Roles.assign_role(user, role.name)
    user
  end

  defp link_contact(user, contact_attrs \\ %{}) do
    {:ok, contact} =
      Contacts.create_contact(
        Map.merge(
          %{name: "Contact", email: "ug-contact-#{System.unique_integer()}@example.com"},
          contact_attrs
        )
      )

    contact |> Contact.link_user_changeset(user.uuid) |> Repo.update!()
  end

  test "list_roles/0 includes a freshly created role" do
    role = create_role()
    assert Enum.any?(UserGroupSource.list_roles(), &(&1.uuid == role.uuid))
  end

  test "sendable_recipients/1 includes an active user with the role" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.sendable_recipients([role.uuid]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 excludes a deactivated user" do
    role = create_role()
    user = create_user() |> assign(role)
    {:ok, _user} = Auth.update_user_status(user, %{"is_active" => false})

    assert UserGroupSource.sendable_recipients([role.uuid]) == []
  end

  test "sendable_recipients/1 excludes a user whose linked contact opted out" do
    role = create_role()
    user = create_user() |> assign(role)
    contact = link_contact(user)
    {:ok, _contact} = Lists.opt_out(contact)

    assert UserGroupSource.sendable_recipients([role.uuid]) == []
  end

  test "sendable_recipients/1 includes a user whose linked contact has NOT opted out" do
    role = create_role()
    user = create_user() |> assign(role)
    link_contact(user)

    assert UserGroupSource.sendable_recipients([role.uuid]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 includes a user with no linked contact at all" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.sendable_recipients([role.uuid]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 dedups a user assigned more than one selected role" do
    role_a = create_role()
    role_b = create_role()
    user = create_user() |> assign(role_a) |> assign(role_b)

    assert UserGroupSource.sendable_recipients([role_a.uuid, role_b.uuid]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 is scoped to the given roles — a user with an unselected role is excluded" do
    role = create_role()
    other_role = create_role()
    create_user() |> assign(other_role)

    assert UserGroupSource.sendable_recipients([role.uuid]) == []
  end

  test "sendable_recipients/1 for an unknown role uuid is []" do
    assert UserGroupSource.sendable_recipients([Ecto.UUID.generate()]) == []
  end

  test "sendable_recipients/1 tolerates a stale role uuid (deleted, or simply garbage) mixed with a role that still exists" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.sendable_recipients([role.uuid, Ecto.UUID.generate()]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  # The whole reason source_params stores uuids, not names (Broadcast's
  # moduledoc): renaming a role must not touch who it resolves to. Uses
  # a custom (non-system) role — Roles.update_role/2 doesn't protect the
  # name of a system role either, but creating one here keeps the test
  # from depending on/mutating shared seed data.
  test "renaming a role after assignment does not change who it resolves to" do
    role = create_role("Before")
    user = create_user() |> assign(role)

    {:ok, renamed_role} = Roles.update_role(role, %{name: "After"})
    assert renamed_role.uuid == role.uuid

    assert UserGroupSource.sendable_recipients([role.uuid]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  # End-to-end version of the "stale uuid" tests above, through the real
  # public API: Roles.delete_role/1 refuses a role that still has
  # assignments (:role_in_use), so a role only becomes genuinely
  # deletable once every member is unassigned — at which point the
  # broadcast's audience has *already* shrunk to that member leaving; the
  # deletion itself doesn't change what the resolver sees, it just makes
  # the "role no longer exists" state permanent instead of "role exists,
  # nobody in it".
  test "a role deleted after its member is unassigned resolves to an empty (not crashed) audience" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.sendable_recipients([role.uuid]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]

    {:ok, _user} = Roles.remove_role(user, role.name)
    assert UserGroupSource.sendable_recipients([role.uuid]) == []

    {:ok, _deleted} = Roles.delete_role(role)
    assert UserGroupSource.sendable_recipients([role.uuid]) == []

    assert UserGroupSource.preflight([role.uuid]) == %{
             total: 0,
             sendable: 0,
             no_email: 0,
             unsendable: 0,
             stale_roles: 1
           }
  end

  test "preflight/1 tolerates a stale role uuid too — reflects only what still resolves, not a crash" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.preflight([role.uuid, Ecto.UUID.generate()]) == %{
             total: 1,
             sendable: 1,
             no_email: 0,
             unsendable: 0,
             stale_roles: 1
           }

    assert user.email != nil
  end

  test "preflight/1 stale_roles is 0 when every given uuid still matches a role" do
    role = create_role()
    create_user() |> assign(role)

    assert %{stale_roles: 0} = UserGroupSource.preflight([role.uuid])
  end

  test "preflight/1 reconciles total = sendable + no_email + unsendable" do
    role = create_role()

    sendable_user = create_user() |> assign(role)

    inactive_user = create_user() |> assign(role)
    {:ok, _} = Auth.update_user_status(inactive_user, %{"is_active" => false})

    opted_out_user = create_user() |> assign(role)
    opted_out_contact = link_contact(opted_out_user)
    {:ok, _} = Lists.opt_out(opted_out_contact)

    assert UserGroupSource.preflight([role.uuid]) == %{
             total: 3,
             sendable: 1,
             no_email: 0,
             unsendable: 2,
             stale_roles: 0
           }

    assert sendable_user.email != nil
  end

  test "preflight/1 returns all-zero counts for a role with no members" do
    role = create_role()

    assert UserGroupSource.preflight([role.uuid]) == %{
             total: 0,
             sendable: 0,
             no_email: 0,
             unsendable: 0,
             stale_roles: 0
           }
  end

  describe "CRM contact lookup is batched, not N+1" do
    defp query_count(fun) do
      test_pid = self()
      handler_id = {:query_count, make_ref()}

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_newsletters, :test, :repo, :query],
        fn _event, _measurements, %{source: source}, _config ->
          send(test_pid, {:query, source})
        end,
        nil
      )

      fun.()

      :telemetry.detach(handler_id)

      messages =
        Stream.repeatedly(fn ->
          receive do
            {:query, source} -> source
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      Enum.count(messages, &(&1 == "phoenix_kit_crm_contacts"))
    end

    test "sendable_recipients/1 issues exactly one contacts query regardless of how many users resolve" do
      role = create_role()
      users = for _ <- 1..5, do: create_user() |> assign(role)
      Enum.each(users, &link_contact/1)

      assert query_count(fn -> UserGroupSource.sendable_recipients([role.uuid]) end) == 1
    end

    test "preflight/1 issues exactly one contacts query regardless of how many users resolve" do
      role = create_role()
      users = for _ <- 1..5, do: create_user() |> assign(role)
      Enum.each(users, &link_contact/1)

      assert query_count(fn -> UserGroupSource.preflight([role.uuid]) end) == 1
    end

    test "no users resolved means no contacts query at all" do
      assert query_count(fn -> UserGroupSource.sendable_recipients([Ecto.UUID.generate()]) end) ==
               0
    end
  end
end
