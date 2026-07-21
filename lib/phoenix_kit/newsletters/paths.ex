defmodule PhoenixKit.Newsletters.Paths do
  @moduledoc "Centralized path helpers for Newsletters module."

  alias PhoenixKit.Utils.Routes

  @base "/admin/newsletters"

  # Broadcasts
  def broadcasts_index, do: Routes.path("#{@base}/broadcasts")
  def broadcast_new, do: Routes.path("#{@base}/broadcasts/new")
  def broadcast_edit(id), do: Routes.path("#{@base}/broadcasts/#{id}/edit")
  def broadcast_show(id), do: Routes.path("#{@base}/broadcasts/#{id}")

  # Public
  def unsubscribe, do: Routes.path("/newsletters/unsubscribe")
end
