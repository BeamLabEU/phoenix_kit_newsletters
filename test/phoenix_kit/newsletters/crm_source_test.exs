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

  alias PhoenixKit.Newsletters.CRMSource
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

  # sendable_recipients/1 defensively dedups by downcased email
  # (Enum.uniq_by), but that path is actually unreachable given the
  # schema: idx_crm_list_members_list_email is a UNIQUE index on
  # (list_uuid, email) over a CITEXT column, so Postgres itself refuses a
  # second member on the same list holding a case-insensitively-equal
  # email — confirmed here directly, which is what the dedup logic
  # guards against ever mattering.
  test "a list cannot hold two members with the same email (case-insensitively) — the invariant sendable_recipients/1's dedup defends",
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
end
