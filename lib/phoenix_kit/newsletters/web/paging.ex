defmodule PhoenixKit.Newsletters.Web.Paging do
  @moduledoc """
  Page arithmetic for the admin lists, from a `?page=` parameter that anyone can
  edit: a value that is not a page, or is past the end, lands on a real one.
  """

  @per_page 50

  @doc "Rows on one page."
  @spec per_page() :: pos_integer()
  def per_page, do: @per_page

  @doc "How many pages `total` rows fill. Never less than one."
  @spec total_pages(non_neg_integer()) :: pos_integer()
  def total_pages(total), do: max(ceil(total / @per_page), 1)

  @doc "The page to show for `param`, and the row offset it starts at."
  @spec resolve(term(), non_neg_integer()) :: {pos_integer(), non_neg_integer()}
  def resolve(param, total) do
    page = param |> parse() |> min(total_pages(total))
    {page, (page - 1) * @per_page}
  end

  defp parse(param) when is_binary(param) do
    case Integer.parse(param) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse(_param), do: 1
end
