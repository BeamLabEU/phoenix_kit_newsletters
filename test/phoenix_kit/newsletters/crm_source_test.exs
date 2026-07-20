defmodule PhoenixKit.Newsletters.CRMSourceTest do
  @moduledoc """
  Exercises the resolver against real `phoenix_kit_crm` fixtures —
  `phoenix_kit_crm` is a test-only dependency (see mix.exs) precisely so
  this suite doesn't have to take the "CRM not installed" behavior on
  faith. Core's own migrations create the CRM tables (V138+), which the
  test DB already carries via `PhoenixKit.Migration.ensure_current/2` in
  test_helper.exs.

  These fixtures reproduce, at small scale, what was already confirmed
  live via Tidewave against real production CRM data (a ~1400-member
  list: 1396 sendable, 0 no-email, 1 unsendable, totals reconciling) —
  see the Stage-4 implementation report for that run.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists

  setup do
    {:ok, list} = Lists.create_list(%{name: "Test List #{System.unique_integer([:positive])}"})
    %{list: list}
  end

  defp add_contact(attrs \\ %{}) do
    base = %{name: "Contact", email: "contact-#{System.unique_integer([:positive])}@example.com"}
    {:ok, contact} = Contacts.create_contact(Map.merge(base, attrs))
    contact
  end

  defp add_member(list, contact) do
    {:ok, member} = Lists.add_contact_to_list(contact, list, source: "manual")
    member
  end

  test "available?/0 is true once phoenix_kit_crm is a loaded dependency" do
    assert CRMSource.available?()
  end

  test "get_list/1 resolves a real list and nil for an unknown uuid", %{list: list} do
    assert CRMSource.get_list(list.uuid).uuid == list.uuid
    assert CRMSource.get_list(Ecto.UUID.generate()) == nil
    assert CRMSource.get_list(nil) == nil
  end

  test "sendable_recipients/1 includes a subscribed contact with an email", %{list: list} do
    contact = add_contact()
    add_member(list, contact)

    assert CRMSource.sendable_recipients(list.uuid) == [
             %{contact_uuid: contact.uuid, email: contact.email}
           ]
  end

  test "sendable_recipients/1 excludes an opted-out contact", %{list: list} do
    contact = add_contact()
    add_member(list, contact)
    {:ok, _contact} = Lists.opt_out(contact)

    assert CRMSource.sendable_recipients(list.uuid) == []
  end

  test "sendable_recipients/1 excludes a subscribed member with no email", %{list: list} do
    contact = add_contact(%{email: nil})
    add_member(list, contact)

    assert CRMSource.sendable_recipients(list.uuid) == []
  end

  test "sendable_recipients/1 excludes a removed member", %{list: list} do
    contact = add_contact()
    member = add_member(list, contact)
    {:ok, _member} = Lists.remove_from_list(member)

    assert CRMSource.sendable_recipients(list.uuid) == []
  end

  # sendable_recipients/1 dedups by downcased email (Enum.uniq_by), but
  # that path can't trigger from a single list today — confirmed here
  # directly: idx_crm_list_members_list_email is a UNIQUE index on
  # (list_uuid, email) over a CITEXT column, so Postgres itself refuses a
  # second member on the same list holding a case-insensitively-equal
  # email. The dedup (and sendable_query/1's deterministic order_by) stay
  # in place for when a caller merges recipients across multiple lists,
  # where this constraint no longer protects against duplicates.
  test "a list cannot hold two members with the same email (case-insensitively)",
       %{list: list} do
    shared_email = "dup-#{System.unique_integer([:positive])}@example.com"
    contact_a = add_contact(%{email: shared_email})
    contact_b = add_contact(%{email: String.upcase(shared_email)})
    add_member(list, contact_a)

    assert {:error, :email_already_in_list} = Lists.add_contact_to_list(contact_b, list)
  end

  test "sendable_recipients/1 is scoped to the given list — a member on a different list is excluded",
       %{list: list} do
    {:ok, other_list} =
      Lists.create_list(%{name: "Other list #{System.unique_integer([:positive])}"})

    other_contact = add_contact()
    add_member(other_list, other_contact)

    assert CRMSource.sendable_recipients(list.uuid) == []
  end

  test "preflight/1 reconciles total = sendable + no_email + unsendable", %{list: list} do
    sendable_contact = add_contact()
    add_member(list, sendable_contact)

    no_email_contact = add_contact(%{email: nil})
    add_member(list, no_email_contact)

    opted_out_contact = add_contact()
    add_member(list, opted_out_contact)
    {:ok, _} = Lists.opt_out(opted_out_contact)

    removed_contact = add_contact()
    removed_member = add_member(list, removed_contact)
    {:ok, _} = Lists.remove_from_list(removed_member)

    assert CRMSource.preflight(list.uuid) == %{
             total: 4,
             sendable: 1,
             no_email: 1,
             unsendable: 2
           }
  end

  test "preflight/1 returns all-zero counts for an empty list", %{list: list} do
    assert CRMSource.preflight(list.uuid) == %{total: 0, sendable: 0, no_email: 0, unsendable: 0}
  end

  test "an archived list is never sendable — sendable_recipients/1 empties out and preflight folds everyone into unsendable",
       %{list: list} do
    contact = add_contact()
    add_member(list, contact)

    assert CRMSource.sendable_recipients(list.uuid) == [
             %{contact_uuid: contact.uuid, email: contact.email}
           ]

    {:ok, _list} = Lists.archive_list(list)

    assert CRMSource.sendable_recipients(list.uuid) == []
    # total still reflects the real membership — archiving doesn't erase
    # history, it just makes every member currently unsendable.
    assert CRMSource.preflight(list.uuid) == %{total: 1, sendable: 0, no_email: 0, unsendable: 1}
  end

  # No real duplicates can occur (the CITEXT unique index above), but the
  # result order should still be a stable, deterministic contract rather
  # than "whatever Postgres feels like" — ordered by member uuid (UUIDv7,
  # so this is also oldest-membership-first).
  test "sendable_recipients/1 returns members in a stable, deterministic order", %{list: list} do
    first = add_member(list, add_contact())
    second = add_member(list, add_contact())

    assert [%{contact_uuid: a}, %{contact_uuid: b}] = CRMSource.sendable_recipients(list.uuid)
    assert a == first.contact_uuid
    assert b == second.contact_uuid
  end

  test "get_contact/1 resolves a real contact and nil for an unknown/nil uuid" do
    contact = add_contact()

    assert CRMSource.get_contact(contact.uuid).uuid == contact.uuid
    assert CRMSource.get_contact(Ecto.UUID.generate()) == nil
    assert CRMSource.get_contact(nil) == nil
  end

  test "get_member_by_email/2 resolves a real membership and nil for an unknown email", %{
    list: list
  } do
    contact = add_contact()
    add_member(list, contact)

    assert %{contact_uuid: contact_uuid} = CRMSource.get_member_by_email(list.uuid, contact.email)
    assert contact_uuid == contact.uuid
    assert CRMSource.get_member_by_email(list.uuid, "nobody@example.com") == nil
  end

  test "remove_from_list/2 is idempotent — a second call on an already-removed membership is a no-op",
       %{list: list} do
    contact = add_contact()
    add_member(list, contact)

    assert {:ok, %{status: "removed"}} = CRMSource.remove_from_list(contact, list)
    assert {:ok, %{status: "removed"}} = CRMSource.remove_from_list(contact, list)
  end

  test "opt_out/1 is idempotent — a second call on an already-opted-out contact is a no-op" do
    contact = add_contact()

    assert {:ok, %{opted_out_at: opted_out_at}} = CRMSource.opt_out(contact)
    assert opted_out_at != nil

    reloaded = CRMSource.get_contact(contact.uuid)
    assert {:ok, %{opted_out_at: ^opted_out_at}} = CRMSource.opt_out(reloaded)
  end

  test "opt_in/1 clears a previous opt_out/1, and is idempotent when not opted out" do
    contact = add_contact()
    {:ok, opted_out} = CRMSource.opt_out(contact)
    assert opted_out.opted_out_at != nil

    assert {:ok, %{opted_out_at: nil}} = CRMSource.opt_in(opted_out)

    reloaded = CRMSource.get_contact(contact.uuid)
    assert {:ok, %{opted_out_at: nil}} = CRMSource.opt_in(reloaded)
  end

  test "list_subscribable_lists/0 only returns active lists with subscribable: true" do
    {:ok, subscribable} =
      Lists.create_list(%{
        name: "Subscribable #{System.unique_integer([:positive])}",
        subscribable: true
      })

    {:ok, _not_subscribable} =
      Lists.create_list(%{name: "Not subscribable #{System.unique_integer([:positive])}"})

    {:ok, archived} =
      Lists.create_list(%{
        name: "Archived #{System.unique_integer([:positive])}",
        subscribable: true
      })

    {:ok, _archived} = Lists.archive_list(archived)

    uuids = CRMSource.list_subscribable_lists() |> Enum.map(& &1.uuid)

    assert subscribable.uuid in uuids
    refute archived.uuid in uuids
  end

  test "subscribed?/2, subscribe/2 and remove_from_list/2 round-trip a contact's membership", %{
    list: list
  } do
    contact = add_contact()

    refute CRMSource.subscribed?(contact, list)

    assert {:ok, _member} = CRMSource.subscribe(contact, list)
    assert CRMSource.subscribed?(contact, list)

    assert {:ok, %{status: "removed"}} = CRMSource.remove_from_list(contact, list)
    refute CRMSource.subscribed?(contact, list)
  end

  # A real core user row: phoenix_kit_crm_contacts.user_uuid carries an FK
  # to it, so linking against a freshly generated uuid violates the
  # constraint. Mirrors the fixture delivery_worker_test.exs uses.
  defp create_core_user(email) do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{email: email})
      |> RepoHelper.repo().insert()

    user
  end

  describe "find_or_link_contact_for_user/1" do
    test "creates and links a new contact when none exists for this user or email" do
      email = "new-user-#{System.unique_integer([:positive])}@example.com"
      user_uuid = create_core_user(email).uuid

      assert {:ok, contact} =
               CRMSource.find_or_link_contact_for_user(%{uuid: user_uuid, email: email})

      assert contact.email == email
      assert contact.user_uuid == user_uuid
    end

    test "is called twice for the same user and creates exactly one contact" do
      email = "repeat-user-#{System.unique_integer([:positive])}@example.com"
      user_uuid = create_core_user(email).uuid
      user = %{uuid: user_uuid, email: email}

      assert {:ok, first} = CRMSource.find_or_link_contact_for_user(user)
      assert {:ok, second} = CRMSource.find_or_link_contact_for_user(user)

      assert first.uuid == second.uuid
      assert length(Contacts.list_by_email(email)) == 1
    end

    test "links an existing contact holding this email, instead of creating a duplicate" do
      email = "existing-contact-#{System.unique_integer([:positive])}@example.com"
      existing = add_contact(%{email: email})
      user_uuid = create_core_user(email).uuid

      assert {:ok, linked} =
               CRMSource.find_or_link_contact_for_user(%{uuid: user_uuid, email: email})

      assert linked.uuid == existing.uuid
      assert linked.user_uuid == user_uuid
      assert length(Contacts.list_by_email(email)) == 1
    end

    test "creates a new contact instead of guessing when the email is ambiguous (N>1 unlinked matches)" do
      email = "ambiguous-#{System.unique_integer([:positive])}@example.com"
      first = add_contact(%{email: email})
      second = add_contact(%{email: email})
      user_uuid = create_core_user(email).uuid

      assert {:ok, linked} =
               CRMSource.find_or_link_contact_for_user(%{uuid: user_uuid, email: email})

      # Neither pre-existing contact was touched — both are still
      # unlinked, and the returned contact is a brand-new third row.
      assert linked.uuid not in [first.uuid, second.uuid]
      assert linked.user_uuid == user_uuid

      reloaded_first = CRMSource.get_contact(first.uuid)
      reloaded_second = CRMSource.get_contact(second.uuid)
      assert reloaded_first.user_uuid == nil
      assert reloaded_second.user_uuid == nil

      assert length(Contacts.list_by_email(email)) == 3
    end

    test "an already-linked contact holding this email doesn't block a fresh link — it's not a candidate" do
      email = "linked-to-someone-else-#{System.unique_integer([:positive])}@example.com"

      other_user_uuid =
        create_core_user("other-#{System.unique_integer([:positive])}@example.com").uuid

      already_linked = add_contact(%{email: email})

      {:ok, already_linked} =
        CRMSource.find_or_link_contact_for_user(%{
          uuid: other_user_uuid,
          email: already_linked.email
        })

      user_uuid = create_core_user(email).uuid

      assert {:ok, linked} =
               CRMSource.find_or_link_contact_for_user(%{uuid: user_uuid, email: email})

      # Not the contact already claimed by the other user — a fresh one.
      assert linked.uuid != already_linked.uuid
      assert linked.user_uuid == user_uuid
    end

    test "never goes through Contacts.connect_user/2 — no placeholder core user is registered" do
      email = "no-placeholder-#{System.unique_integer([:positive])}@example.com"
      user_uuid = create_core_user(email).uuid

      assert {:ok, _contact} =
               CRMSource.find_or_link_contact_for_user(%{uuid: user_uuid, email: email})

      # connect_user/2's placeholder path registers a core user tagged
      # custom_fields["source"] == "crm_contact". This flow must link to
      # the user that already exists and register nobody: the account
      # under this address stays the one the fixture created (same uuid,
      # untouched tag), and no second account appears for it.
      linked_user = Auth.get_user_by_email(email)

      assert linked_user.uuid == user_uuid
      refute linked_user.custom_fields["source"] == "crm_contact"

      assert RepoHelper.repo().aggregate(
               from(u in User, where: u.email == ^email),
               :count
             ) == 1
    end
  end
end
