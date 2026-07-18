defmodule PhoenixKit.Newsletters.CRMSourceTest do
  @moduledoc """
  `phoenix_kit_crm` is not a dependency of this package (nor a test-only
  one), so `available?/0` is always false in this suite and these tests
  can only exercise the "CRM not installed" degrade-gracefully path —
  every public function here must be safe to call with zero CRM present.

  The actual resolver query (`status == "subscribed"`, contact not
  opted out, email present, deduplicated) and the preflight counts were
  verified live against real CRM list data via Tidewave (a ~1400-member
  list: 1396 sendable, 0 no-email, 1 unsendable, totals reconciling) —
  see the Stage-4 implementation report rather than a fixture here.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.CRMSource

  test "available?/0 is false when the CRM module isn't installed" do
    refute CRMSource.available?()
  end

  test "list_lists/0 returns an empty list when CRM isn't installed" do
    assert CRMSource.list_lists() == []
  end

  test "get_list/1 returns nil when CRM isn't installed" do
    assert CRMSource.get_list(Ecto.UUID.generate()) == nil
  end

  test "get_list/1 returns nil for nil input regardless of CRM availability" do
    assert CRMSource.get_list(nil) == nil
  end

  test "sendable_recipients/1 returns an empty list when CRM isn't installed" do
    assert CRMSource.sendable_recipients(Ecto.UUID.generate()) == []
  end

  test "preflight/1 returns all-zero counts when CRM isn't installed" do
    assert CRMSource.preflight(Ecto.UUID.generate()) == %{
             total: 0,
             sendable: 0,
             no_email: 0,
             unsendable: 0
           }
  end
end
