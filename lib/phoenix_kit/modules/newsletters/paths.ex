defmodule PhoenixKit.Modules.Newsletters.Paths do
  @moduledoc "Centralized path helpers for Newsletters module."

  alias PhoenixKit.Utils.Routes

  @base "/admin/newsletters"

  # Broadcasts
  def broadcasts_index, do: Routes.path("#{@base}/broadcasts")
  def broadcast_new, do: Routes.path("#{@base}/broadcasts/new")
  def broadcast_edit(id), do: Routes.path("#{@base}/broadcasts/#{id}/edit")
  def broadcast_show(id), do: Routes.path("#{@base}/broadcasts/#{id}")

  # Lists
  def lists_index, do: Routes.path("#{@base}/lists")
  def list_new, do: Routes.path("#{@base}/lists/new")
  def list_edit(id), do: Routes.path("#{@base}/lists/#{id}/edit")
  def list_members(id), do: Routes.path("#{@base}/lists/#{id}/members")

  # Public
  def unsubscribe, do: Routes.path("/newsletters/unsubscribe")
end
