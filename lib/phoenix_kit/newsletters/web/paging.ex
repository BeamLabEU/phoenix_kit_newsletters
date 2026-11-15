defmodule PhoenixKit.Newsletters.Web.Paging do
  @moduledoc """
  Page arithmetic for the admin lists. The page and its size come from the URL
  through `PhoenixKitWeb.Live.UrlState` and `PhoenixKitWeb.PageSize`, already cast
  and bounded; what is left is a page past the end, which lands on the last one.
  """

  @doc "How many pages `total` rows fill at `per_page`. Never less than one."
  @spec total_pages(non_neg_integer(), pos_integer()) :: pos_integer()
  def total_pages(total, per_page), do: max(ceil(total / per_page), 1)

  @doc "The page to show for `page`, kept within the list, and the row offset it starts at."
  @spec resolve(pos_integer(), non_neg_integer(), pos_integer()) ::
          {pos_integer(), non_neg_integer()}
  def resolve(page, total, per_page) do
    page = page |> max(1) |> min(total_pages(total, per_page))
    {page, (page - 1) * per_page}
  end
end
