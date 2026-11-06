defmodule PhoenixKit.Newsletters.Paths do
  @moduledoc "Centralized path helpers for Newsletters module."

  alias PhoenixKit.Utils.Routes
  alias Plug.Conn.Query

  @base "/admin/newsletters"

  # Broadcasts
  def broadcasts_index, do: Routes.path("#{@base}/broadcasts")
  def broadcast_new, do: Routes.path("#{@base}/broadcasts/new")
  def broadcast_edit(id), do: Routes.path("#{@base}/broadcasts/#{id}/edit")
  def broadcast_show(id), do: Routes.path("#{@base}/broadcasts/#{id}")

  # Layouts
  def layouts_index, do: Routes.path("#{@base}/layouts")
  def layout_new, do: Routes.path("#{@base}/layouts/new")
  def layout_edit(id), do: Routes.path("#{@base}/layouts/#{id}/edit")

  # Address verification
  def verification_index(params \\ %{}) do
    case params |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end) |> Map.new() do
      query when map_size(query) == 0 -> Routes.path("#{@base}/verification")
      query -> Routes.path("#{@base}/verification") <> "?" <> Query.encode(query)
    end
  end

  # Public. The unsubscribe routes exist at the root only, in every language, so
  # a locale segment would point at nothing: on a multilingual site that is every
  # link in every mail. The link's token says which language to answer in.
  def unsubscribe, do: public("/newsletters/unsubscribe")
  def preferences, do: public("/newsletters/preferences")

  def unsubscribe_url(token), do: public_url("/newsletters/unsubscribe", token)

  def one_click_unsubscribe_url(token),
    do: public_url("/newsletters/unsubscribe/one-click", token)

  def preferences_url(token), do: public_url("/newsletters/preferences", token)

  defp public(path), do: Routes.path(path, locale: :none)

  defp public_url(path, token) do
    Routes.base_url() <> public(path) <> "?" <> URI.encode_query(token: token)
  end
end
