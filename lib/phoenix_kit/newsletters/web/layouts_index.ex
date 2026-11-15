defmodule PhoenixKit.Newsletters.Web.LayoutsIndex do
  @moduledoc """
  LiveView listing broadcast layouts: archive/restore, and the default
  layout new broadcasts start with (`newsletters_default_template`).
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Badge, only: [status_badge: 1]
  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # The status filter lives in the query string. Active is the default, so an
  # unfiltered list has no `?status=`. A value that is not a status is dropped.
  use PhoenixKitWeb.Live.UrlState,
    params: [
      status_filter: [
        default: "active",
        url_key: "status",
        in: ~w(active archived all)
      ]
    ]

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      {:ok,
       socket
       |> assign(:page_title, gettext("Layouts"))
       |> assign(:page_subtitle, gettext("The HTML your broadcasts are sent inside"))
       |> assign(:page_section, gettext("Newsletters"))
       |> assign(:page_section_path, Paths.broadcasts_index())
       |> assign(:project_title, Settings.get_project_title())
       |> assign_new(:current_locale, fn -> nil end)
       # :status_filter comes from the URL, assigned by UrlState before mount.
       |> assign(:layouts, [])
       |> assign(:default_uuid, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  # UrlState has already judged the status by the time this runs.
  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load(socket)}
  end

  @impl true
  def handle_url_state(_state, socket), do: socket

  @impl true
  # UrlState drops a status that does not exist; only a string gets that far.
  def handle_event("filter_status", %{"status" => status}, socket) when is_binary(status) do
    {:noreply, push_url_state(socket, status_filter: status)}
  end

  def handle_event("filter_status", _params, socket), do: {:noreply, socket}

  def handle_event("archive", %{"uuid" => uuid}, socket) do
    with %Layout{} = layout <- Layouts.get_layout(uuid),
         {:ok, _layout} <- Layouts.archive_layout(layout) do
      {:noreply, socket |> put_flash(:info, gettext("Layout archived")) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not archive the layout"))}
    end
  end

  def handle_event("restore", %{"uuid" => uuid}, socket) do
    with %Layout{} = layout <- Layouts.get_layout(uuid),
         {:ok, _layout} <- Layouts.restore_layout(layout) do
      {:noreply, socket |> put_flash(:info, gettext("Layout restored")) |> load()}
    else
      {:error, :system_email} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A system email carried over for old broadcasts stays archived")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not restore the layout"))}
    end
  end

  def handle_event("set_default", %{"uuid" => uuid}, socket) do
    case Layouts.set_default_layout(uuid) do
      :ok ->
        {:noreply, socket |> put_flash(:info, gettext("Default layout updated")) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Only an active layout can be the default"))}
    end
  end

  def handle_event("clear_default", _params, socket) do
    case Layouts.set_default_layout(nil) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("New broadcasts now start with the standard layout"))
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the default layout"))}
    end
  end

  defp load(socket) do
    status = if socket.assigns.status_filter == "all", do: nil, else: socket.assigns.status_filter

    socket
    |> assign(:layouts, Layouts.list_layouts(status: status))
    |> assign(:default_uuid, Layouts.default_layout_uuid())
  end

  defp status_label("active"), do: gettext("Active")
  defp status_label("archived"), do: gettext("Archived")
  defp status_label(other), do: other
end
