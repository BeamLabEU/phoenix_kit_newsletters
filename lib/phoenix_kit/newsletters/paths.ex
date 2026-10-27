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

  # Core's email sending settings page; modules contribute their own sections to
  # it (a verification engine's SMTP runner among them)
  def email_sending_settings, do: Routes.path("/admin/settings/email-sending")

  # Public
  def unsubscribe, do: Routes.path("/newsletters/unsubscribe")
end
