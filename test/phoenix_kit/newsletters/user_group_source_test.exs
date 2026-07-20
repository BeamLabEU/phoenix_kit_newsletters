defmodule PhoenixKit.Newsletters.UserGroupSourceTest do
  @moduledoc """
  Exercises the resolver against real core Roles/User fixtures — Roles is
  a hard dependency of newsletters, so unlike `CRMSourceTest` this needs
  no `available?/0` gate. The CRM opt-out check is exercised too:
  `phoenix_kit_crm` is a test-only dependency (see mix.exs), so the
  "linked contact opted out" path is real, not simulated.
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

  test "list_role_names/0 includes a freshly created role" do
    role = create_role()
    assert role.name in UserGroupSource.list_role_names()
  end

  test "sendable_recipients/1 includes an active user with the role" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.sendable_recipients([role.name]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 excludes a deactivated user" do
    role = create_role()
    user = create_user() |> assign(role)
    {:ok, _user} = Auth.update_user_status(user, %{"is_active" => false})

    assert UserGroupSource.sendable_recipients([role.name]) == []
  end

  test "sendable_recipients/1 excludes a user whose linked contact opted out" do
    role = create_role()
    user = create_user() |> assign(role)
    contact = link_contact(user)
    {:ok, _contact} = Lists.opt_out(contact)

    assert UserGroupSource.sendable_recipients([role.name]) == []
  end

  test "sendable_recipients/1 includes a user whose linked contact has NOT opted out" do
    role = create_role()
    user = create_user() |> assign(role)
    link_contact(user)

    assert UserGroupSource.sendable_recipients([role.name]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 includes a user with no linked contact at all" do
    role = create_role()
    user = create_user() |> assign(role)

    assert UserGroupSource.sendable_recipients([role.name]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 dedups a user assigned more than one selected role" do
    role_a = create_role()
    role_b = create_role()
    user = create_user() |> assign(role_a) |> assign(role_b)

    assert UserGroupSource.sendable_recipients([role_a.name, role_b.name]) == [
             %{user_uuid: user.uuid, email: user.email}
           ]
  end

  test "sendable_recipients/1 is scoped to the given roles — a user with an unselected role is excluded" do
    role = create_role()
    other_role = create_role()
    create_user() |> assign(other_role)

    assert UserGroupSource.sendable_recipients([role.name]) == []
  end

  test "sendable_recipients/1 for an unknown role name is []" do
    assert UserGroupSource.sendable_recipients(["NonexistentRole"]) == []
  end

  test "preflight/1 reconciles total = sendable + no_email + unsendable" do
    role = create_role()

    sendable_user = create_user() |> assign(role)

    inactive_user = create_user() |> assign(role)
    {:ok, _} = Auth.update_user_status(inactive_user, %{"is_active" => false})

    opted_out_user = create_user() |> assign(role)
    opted_out_contact = link_contact(opted_out_user)
    {:ok, _} = Lists.opt_out(opted_out_contact)

    assert UserGroupSource.preflight([role.name]) == %{
             total: 3,
             sendable: 1,
             no_email: 0,
             unsendable: 2
           }

    assert sendable_user.email != nil
  end

  test "preflight/1 returns all-zero counts for a role with no members" do
    role = create_role()

    assert UserGroupSource.preflight([role.name]) == %{
             total: 0,
             sendable: 0,
             no_email: 0,
             unsendable: 0
           }
  end
end
