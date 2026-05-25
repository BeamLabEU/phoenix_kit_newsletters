defmodule PhoenixKit.Newsletters.Web.BroadcastDetails do
  @moduledoc """
  LiveView for viewing broadcast details and delivery statistics.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.PkLink
  import PhoenixKitWeb.Components.Core.TableDefault

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Optional soft dependency — use module atom to avoid compile-time warnings
  @email_template_mod PhoenixKit.Modules.Emails.Template

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:broadcast_id, nil)
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:broadcast, nil)
        |> assign(:deliveries, [])
        |> assign(:delivery_stats, %{})
        |> assign(:loading, true)
        |> assign(:show_confirm_modal, false)
        |> assign(:confirm_action, nil)
        |> assign(:confirm_target, nil)
        |> assign(:confirm_title, "")
        |> assign(:confirm_message, "")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply,
     socket
     |> assign(:broadcast_id, id)
     |> assign(:loading, true)
     |> load_broadcast_data()}
  end

  @impl true
  def handle_event("show_confirm", %{"action" => "cancel_broadcast"}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :cancel_broadcast)
     |> assign(:confirm_title, gettext("Cancel broadcast"))
     |> assign(
       :confirm_message,
       gettext("This will stop any remaining deliveries for this broadcast.")
     )}
  end

  @impl true
  def handle_event("hide_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, false)
     |> assign(:confirm_action, nil)}
  end

  @impl true
  def handle_event("confirm_action", _params, socket) do
    socket = assign(socket, :show_confirm_modal, false)

    case socket.assigns.confirm_action do
      :cancel_broadcast ->
        case Newsletters.update_broadcast(socket.assigns.broadcast, %{status: "cancelled"}) do
          {:ok, broadcast} ->
            {:noreply,
             socket
             |> assign(:broadcast, broadcast)
             |> put_flash(:info, gettext("Broadcast cancelled"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to cancel broadcast"))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_broadcast_data()}
  end

  # --- Private ---

  defp load_broadcast_data(socket) do
    id = socket.assigns.broadcast_id

    try do
      broadcast = Newsletters.get_broadcast_with_template!(id)
      deliveries = Newsletters.list_deliveries(id)
      stats = Newsletters.get_delivery_stats(id)

      socket
      |> assign(:broadcast, broadcast)
      |> assign(:deliveries, deliveries)
      |> assign(:delivery_stats, stats)
      |> assign(:loading, false)
      |> assign(:page_title, broadcast.subject)
    rescue
      Ecto.NoResultsError ->
        socket
        |> assign(:loading, false)
        |> put_flash(:error, gettext("Broadcast not found"))
        |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))
    end
  end

  def status_label(status), do: gettext_status(status)

  defp gettext_status("draft"), do: gettext("Draft")
  defp gettext_status("scheduled"), do: gettext("Scheduled")
  defp gettext_status("sending"), do: gettext("Sending")
  defp gettext_status("sent"), do: gettext("Sent")
  defp gettext_status("cancelled"), do: gettext("Cancelled")
  defp gettext_status(other), do: other

  def delivery_label(status), do: gettext_delivery(status)

  defp gettext_delivery("pending"), do: gettext("Pending")
  defp gettext_delivery("sent"), do: gettext("Sent")
  defp gettext_delivery("delivered"), do: gettext("Delivered")
  defp gettext_delivery("opened"), do: gettext("Opened")
  defp gettext_delivery("bounced"), do: gettext("Bounced")
  defp gettext_delivery("failed"), do: gettext("Failed")
  defp gettext_delivery(other), do: other

  defp status_badge_class(status) do
    case status do
      "draft" -> "badge-ghost"
      "scheduled" -> "badge-info"
      "sending" -> "badge-warning"
      "sent" -> "badge-success"
      "cancelled" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp delivery_badge_class(status) do
    case status do
      "pending" -> "badge-ghost"
      "sent" -> "badge-info"
      "delivered" -> "badge-success"
      "opened" -> "badge-primary"
      "bounced" -> "badge-warning"
      "failed" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp stat_value(stats, key) do
    Map.get(stats, key, 0)
  end

  defp template_display_name(template) do
    if Code.ensure_loaded?(@email_template_mod) do
      soft_call(@email_template_mod, :get_translation, [template.display_name, "en"]) ||
        template.name
    else
      template.name
    end
  end

  # Intentional apply/3 — calls optional soft-dependency modules to avoid compile-time warnings
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_call(mod, fun, args), do: apply(mod, fun, args)
end
