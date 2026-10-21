defmodule PhoenixKit.Newsletters.VerificationRows do
  @moduledoc """
  The table behind the address-verification page, as plain data: one row per
  audience address joined with its stored verdict, the status filter over those
  rows, and their pagination. No engine calls and no database — `Web.Verification`
  feeds it the audience's addresses and `EmailVerification.statuses_for/1` / `results_for/1`.
  """

  @statuses ~w(valid invalid temp not_sure unchecked)
  @default_per_page 50

  # The SMTP check was tried and gave up on the connection: the verdict is a
  # not_sure at level "mx", but "Domain OK (no SMTP)" would say it was not tried.
  @smtp_transport_failures ~w(smtp_timeout smtp_connect_failed smtp_reset smtp_unavailable)

  @type status :: :valid | :invalid | :temp | :not_sure | :unchecked
  @type row :: %{email: String.t(), status: status(), result: map() | nil}

  @doc "The values the `?status=` filter accepts."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The page size."
  @spec per_page() :: pos_integer()
  def per_page, do: @default_per_page

  @doc """
  Joins `emails` with `results` (the engine's map, keyed by the address as
  given). A repeated address is one row. Ordered by address, case-insensitively.
  """
  @spec build([String.t()], %{String.t() => map()}) :: [row()]
  def build(emails, results) when is_list(emails) and is_map(results) do
    emails
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&String.downcase/1)
    |> Enum.map(fn email ->
      result = Map.get(results, email)
      %{email: email, status: status_of(result), result: result}
    end)
  end

  @doc """
  One page of the table for `emails`: `{rows, %{page:, total_pages:, total:}}`.

  `fetch_statuses` (the engine's `statuses_for/1`, light maps without the step
  logs) and `fetch_results` (`results_for/1`, full verdicts) are called with the
  addresses they are needed for. Without a status filter only the shown page is
  looked up, for full results. With one, every address is looked up for its
  status, because the status decides which rows belong on the page; the full
  results are then loaded for the page's rows only.
  """
  @spec table(
          [String.t()],
          String.t(),
          pos_integer(),
          ([String.t()] -> %{String.t() => map()}),
          ([String.t()] -> %{String.t() => map()}),
          pos_integer()
        ) ::
          {[row()], %{page: pos_integer(), total_pages: pos_integer(), total: non_neg_integer()}}
  def table(emails, status, page, fetch_statuses, fetch_results, per_page \\ @default_per_page) do
    rows =
      if parse_status(status) == "" do
        build(emails, %{})
      else
        emails |> build(fetch_statuses.(emails)) |> filter(status)
      end

    {page_rows, meta} = paginate(rows, page, per_page)
    page_emails = Enum.map(page_rows, & &1.email)
    {build(page_emails, fetch_results.(page_emails)), meta}
  end

  @doc "The status atom of a stored verdict; `:unchecked` for none."
  @spec status_of(map() | nil) :: status()
  def status_of(nil), do: :unchecked

  def status_of(result) do
    case Map.get(result, :status) do
      "valid" -> :valid
      "invalid" -> :invalid
      "temp" -> :temp
      "not_sure" -> :not_sure
      _ -> :unchecked
    end
  end

  @doc """
  What the status badge says. `:smtp_pending` is an address whose mailbox is
  queued for the SMTP check (`not_sure`, reason `"smtp_pending"`). `:mx_ok` is
  the verdict of an address that passed syntax, word lists and DNS but whose
  mailbox was not probed — `not_sure` at level `"mx"` — not a plain "not sure".
  An SMTP check that was tried and lost its connection is also `not_sure` at
  level `"mx"`, but it is a plain "not sure": it did probe.
  """
  @spec badge_kind(row()) :: status() | :mx_ok | :smtp_pending
  def badge_kind(%{status: :not_sure, result: result}) when is_map(result) do
    case result do
      %{reason: "smtp_pending"} -> :smtp_pending
      %{reason: reason} when reason in @smtp_transport_failures -> :not_sure
      %{level: "mx"} -> :mx_ok
      _ -> :not_sure
    end
  end

  def badge_kind(%{status: status}), do: status

  @doc "Keeps the rows of one status; `\"\"` (or anything unknown) keeps all."
  @spec filter([row()], String.t() | nil) :: [row()]
  def filter(rows, status) when status in @statuses do
    atom = String.to_existing_atom(status)
    Enum.filter(rows, &(&1.status == atom))
  end

  def filter(rows, _status), do: rows

  @doc "A `?status=` value as the filter takes it: a known status, else `\"\"`."
  @spec parse_status(term()) :: String.t()
  def parse_status(status) when status in @statuses, do: status
  def parse_status(_status), do: ""

  @doc "A `?page=` value as a positive integer; `1` for anything else."
  @spec parse_page(term()) :: pos_integer()
  def parse_page(page) when is_integer(page) and page > 0, do: page

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  def parse_page(_page), do: 1

  @doc """
  One page of `rows`. A page past the end is clamped to the last one, so a
  filter that shrinks the list never shows an empty page.
  """
  @spec paginate([row()], pos_integer(), pos_integer()) ::
          {[row()], %{page: pos_integer(), total_pages: pos_integer(), total: non_neg_integer()}}
  def paginate(rows, page, per_page \\ @default_per_page) do
    total = length(rows)
    total_pages = max(div(total + per_page - 1, per_page), 1)
    page = page |> max(1) |> min(total_pages)

    page_rows = rows |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
    {page_rows, %{page: page, total_pages: total_pages, total: total}}
  end
end
