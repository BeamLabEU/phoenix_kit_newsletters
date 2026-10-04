defmodule PhoenixKit.Newsletters.Web.LayoutsIndex do
  @moduledoc """
  LiveView listing broadcast layouts: archive/restore, and the default
  layout new broadcasts start with (`newsletters_default_template`).
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.PkLink

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

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
       |> assign(:status_filter, "active")
       |> assign(:layouts, [])
       |> assign(:default_uuid, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    status =
      if params["status"] in ["active", "archived", "all"], do: params["status"], else: "active"

    {:noreply, socket |> assign(:status_filter, status) |> load()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket, to: Paths.layouts_index() <> "?status=#{URI.encode_www_form(status)}")}
  end

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
