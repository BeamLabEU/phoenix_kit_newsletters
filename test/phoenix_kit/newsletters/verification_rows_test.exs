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

  describe "badge_kind/1 for the SMTP stage" do
    test "not_sure waiting for the SMTP stage is its own badge, still a not_sure row" do
      pending = result("not_sure", %{reason: "smtp_pending"})
      [row] = VerificationRows.build(["g@x.com"], %{"g@x.com" => pending})

      assert row.status == :not_sure
      assert VerificationRows.badge_kind(row) == :smtp_pending
    end

    test "the SMTP verdict reasons do not change the badge of their status" do
      for {status, reason} <- [{"not_sure", "catch_all"}, {"invalid", "mailbox_unknown"}] do
        [row] =
          VerificationRows.build(["g@x.com"], %{
            "g@x.com" => result(status, %{reason: reason, level: "smtp"})
          })

        assert VerificationRows.badge_kind(row) == String.to_existing_atom(status)
      end
    end

    test "a transport failure of the SMTP check is a plain not-sure, not a domain-ok badge" do
      for reason <- ~w(smtp_timeout smtp_connect_failed smtp_reset smtp_unavailable) do
        [row] =
          VerificationRows.build(["g@x.com"], %{
            "g@x.com" => result("not_sure", %{reason: reason, level: "mx"})
          })

        assert VerificationRows.badge_kind(row) == :not_sure, reason
      end
    end

    test "a verdict from a statuses_for/1 map (no flags, no log) reads the same" do
      [row] =
        VerificationRows.build(["g@x.com"], %{
          "g@x.com" => %{status: "not_sure", reason: "smtp_pending", level: "mx"}
        })

      assert VerificationRows.badge_kind(row) == :smtp_pending
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

  describe "table/6" do
    defp fetch_statuses(emails) do
      send(self(), {:statuses, emails})

      emails
      |> then(&Map.take(results(), &1))
      |> Map.new(fn {email, result} -> {email, Map.take(result, [:status, :reason, :level])} end)
    end

    defp fetch_results(emails) do
      send(self(), {:fetched, emails})
      Map.take(results(), emails)
    end

    defp table(status, page, per_page \\ 50) do
      VerificationRows.table(
        @emails,
        status,
        page,
        &fetch_statuses/1,
        &fetch_results/1,
        per_page
      )
    end

    test "without a filter only the shown page is looked up, and only for full results" do
      {rows, meta} = table("", 2, 4)

      assert_received {:fetched, fetched}
      assert fetched == ~w(e@x.com f@x.com)
      refute_received {:fetched, _}
      refute_received {:statuses, _}
      assert Enum.map(rows, & &1.status) == [:temp, :unchecked]
      assert meta.total == 6
    end

    test "with a filter every address is looked up for its status, the full result only for the page" do
      {rows, meta} = table("not_sure", 1, 1)

      assert_received {:statuses, statuses}
      assert length(statuses) == 6

      assert_received {:fetched, fetched}
      assert fetched == ["c@x.com"]
      refute_received {:fetched, _}

      assert Enum.map(rows, & &1.email) == ["c@x.com"]
      assert meta == %{page: 1, total_pages: 2, total: 2}
    end

    test "a filtered row carries the full result, not the status-only map" do
      {[row], _meta} = table("valid", 1)
      assert row.result == results()["a@x.com"]
    end

    test "the unchecked filter lists addresses with no verdict" do
      {rows, _meta} = table("unchecked", 1)
      assert Enum.map(rows, & &1.email) == ["f@x.com"]
    end
  end
end
