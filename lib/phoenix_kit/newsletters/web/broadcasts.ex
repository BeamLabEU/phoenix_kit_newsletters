defmodule PhoenixKit.Newsletters.Web.Broadcasts do
  @moduledoc """
  LiveView for the broadcasts list in the newsletters admin panel.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.PkLink
  import PhoenixKitWeb.Components.Core.TableDefault

  import PhoenixKit.Newsletters.Web.Timezone, only: [format_datetime: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      tz_offset = Timezone.user_tz_offset(socket)

      socket =
        socket
        |> assign(:page_title, gettext("Broadcasts"))
        |> assign(:page_subtitle, gettext("Create and manage email broadcasts"))
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:broadcasts, [])
        |> assign(:status_filter, "")
        |> assign(:tz_offset, tz_offset)
        |> assign(:tz_label, Timezone.tz_label(tz_offset))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = params["status"] || ""

    broadcasts = Newsletters.list_broadcasts(%{status: status})

    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:broadcasts, broadcasts)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    params = if status == "", do: %{}, else: %{"status" => status}
    query = URI.encode_query(params)

    path =
      if query == "",
        do: "/admin/newsletters/broadcasts",
        else: "/admin/newsletters/broadcasts?#{query}"

    {:noreply, push_patch(socket, to: Routes.path(path))}
  end

  @impl true
  def handle_event("view_broadcast", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/newsletters/broadcasts/#{uuid}"))}
  end

  defp status_badge_class(status) do
    case status do
      "draft" -> "badge-ghost"
      "scheduled" -> "badge-info"
      "sending" -> "badge-warning"
      "sent" -> "badge-success"
      "cancelled" -> "badge-error"
      "failed" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  def status_label(status), do: gettext_status(status)

  defp gettext_status("draft"), do: gettext("Draft")
  defp gettext_status("scheduled"), do: gettext("Scheduled")
  defp gettext_status("sending"), do: gettext("Sending")
  defp gettext_status("sent"), do: gettext("Sent")
  defp gettext_status("cancelled"), do: gettext("Cancelled")
  defp gettext_status("failed"), do: gettext("Failed")
  defp gettext_status(other), do: other
end
