defmodule PhoenixKit.Newsletters.VerificationRowsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.VerificationRows

  defp result(status, extra \\ %{}), do: Map.merge(%{status: status, level: "mx"}, extra)

  defp results do
    %{
      "a@x.com" => result("valid", %{level: "smtp"}),
      "b@x.com" => result("invalid", %{reason: "no_mx"}),
      "c@x.com" => result("not_sure", %{reason: "smtp_disabled"}),
      "d@x.com" => result("not_sure", %{level: "dict"}),
      "e@x.com" => result("temp")
    }
  end

  @emails ~w(e@x.com d@x.com c@x.com b@x.com a@x.com f@x.com)

  describe "build/2" do
    test "joins addresses with their verdicts, ordered by address" do
      rows = VerificationRows.build(@emails, results())

      assert Enum.map(rows, & &1.email) == ~w(a@x.com b@x.com c@x.com d@x.com e@x.com f@x.com)

      assert Enum.map(rows, & &1.status) ==
               [:valid, :invalid, :not_sure, :not_sure, :temp, :unchecked]
    end

    test "an address without a verdict is unchecked, with no result" do
      assert [%{email: "f@x.com", status: :unchecked, result: nil}] =
               VerificationRows.build(["f@x.com"], %{})
    end

    test "a repeated address (any case) is one row" do
      rows = VerificationRows.build(["A@x.com", "a@x.com", "b@x.com"], %{})
      assert Enum.map(rows, & &1.email) == ["A@x.com", "b@x.com"]
    end

    test "an unknown status string reads as unchecked" do
      assert VerificationRows.status_of(%{status: "weird"}) == :unchecked
    end
  end

  describe "badge_kind/1" do
    test "not_sure at level mx is the domain-ok badge, not a plain not-sure" do
      kinds =
        @emails
        |> VerificationRows.build(results())
        |> Map.new(&{&1.email, VerificationRows.badge_kind(&1)})

      assert kinds["c@x.com"] == :mx_ok
      assert kinds["d@x.com"] == :not_sure
      assert kinds["a@x.com"] == :valid
      assert kinds["b@x.com"] == :invalid
      assert kinds["e@x.com"] == :temp
      assert kinds["f@x.com"] == :unchecked
    end
  end

  describe "filter/2" do
    test "keeps one status; blank or unknown keeps all" do
      rows = VerificationRows.build(@emails, results())

      assert rows |> VerificationRows.filter("not_sure") |> Enum.map(& &1.email) ==
               ~w(c@x.com d@x.com)

      assert rows |> VerificationRows.filter("unchecked") |> Enum.map(& &1.email) == ["f@x.com"]
      assert length(VerificationRows.filter(rows, "")) == 6
      assert length(VerificationRows.filter(rows, "bogus")) == 6
      assert length(VerificationRows.filter(rows, nil)) == 6
    end
  end

  describe "parse_status/1 and parse_page/1" do
    test "only known statuses and positive integers get through" do
      assert VerificationRows.parse_status("valid") == "valid"
      assert VerificationRows.parse_status("nope") == ""
      assert VerificationRows.parse_status(nil) == ""
      assert VerificationRows.parse_page("3") == 3
      assert VerificationRows.parse_page("0") == 1
      assert VerificationRows.parse_page("-2") == 1
      assert VerificationRows.parse_page("2x") == 1
      assert VerificationRows.parse_page(nil) == 1
    end
  end

  describe "paginate/3" do
    test "slices a page and counts pages" do
      rows = VerificationRows.build(@emails, %{})

      {page_rows, meta} = VerificationRows.paginate(rows, 2, 4)
      assert Enum.map(page_rows, & &1.email) == ~w(e@x.com f@x.com)
      assert meta == %{page: 2, total_pages: 2, total: 6}
    end

    test "a page past the end is clamped to the last one" do
      rows = VerificationRows.build(@emails, %{})
      {page_rows, meta} = VerificationRows.paginate(rows, 9, 4)
      assert meta.page == 2
      assert length(page_rows) == 2
    end

    test "no rows is one empty page" do
      assert {[], %{page: 1, total_pages: 1, total: 0}} = VerificationRows.paginate([], 3, 4)
    end
  end

  describe "table/5" do
    defp fetch(emails) do
      send(self(), {:fetched, emails})
      Map.take(results(), emails)
    end

    test "without a filter only the shown page is looked up" do
      {rows, meta} = VerificationRows.table(@emails, "", 2, &fetch/1, 4)

      assert_received {:fetched, fetched}
      assert fetched == ~w(e@x.com f@x.com)
      refute_received {:fetched, _}
      assert Enum.map(rows, & &1.status) == [:temp, :unchecked]
      assert meta.total == 6
    end

    test "with a filter every address is looked up, then filtered and paged" do
      {rows, meta} = VerificationRows.table(@emails, "not_sure", 1, &fetch/1, 1)

      assert_received {:fetched, fetched}
      assert length(fetched) == 6
      assert Enum.map(rows, & &1.email) == ["c@x.com"]
      assert meta == %{page: 1, total_pages: 2, total: 2}
    end

    test "the unchecked filter lists addresses with no verdict" do
      {rows, _meta} = VerificationRows.table(@emails, "unchecked", 1, &fetch/1)
      assert Enum.map(rows, & &1.email) == ["f@x.com"]
    end
  end
end
