defmodule PhoenixKit.Newsletters.Web.Broadcasts do
  @moduledoc """
  LiveView for the broadcasts list in the newsletters admin panel.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Pagination
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.TableDefault

  import PhoenixKit.Newsletters.Web.Timezone, only: [format_datetime: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.Web.Paging
  alias PhoenixKit.Newsletters.Web.StatusLabel
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:page_title, gettext("Newsletters"))
        |> assign(:page_subtitle, gettext("Create and manage email broadcasts"))
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:broadcasts, [])
        |> assign(:status_filter, "")
        |> assign(:page, 1)
        |> assign(:per_page, Paging.per_page())
        |> assign(:total_count, 0)
        |> assign(:total_pages, 1)

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
    status = status_param(params["status"])
    total = Newsletters.count_broadcasts(%{status: status})
    {page, offset} = Paging.resolve(params["page"], total)

    broadcasts =
      Newsletters.list_broadcasts(%{status: status, limit: Paging.per_page(), offset: offset})

    {:noreply,
     socket
     |> assign_tz()
     |> assign(:status_filter, status)
     |> assign(:broadcasts, broadcasts)
     |> assign(:page, page)
     |> assign(:total_count, total)
     |> assign(:total_pages, Paging.total_pages(total))}
  end

  # Only a status that exists: the rest would show nothing, or raise further down
  # for a value that is not a string at all.
  defp status_param(status) do
    if status in Broadcast.valid_statuses(), do: status, else: ""
  end

  defp page_url(page, status) do
    params = Enum.reject([status: status, page: page], fn {_k, v} -> v in ["", 1] end)

    case URI.encode_query(params) do
      "" -> Paths.broadcasts_index()
      query -> Paths.broadcasts_index() <> "?" <> query
    end
  end

  # Resolves and assigns the viewer's timezone from handle_params (not
  # mount, which runs twice per connection — once for the disconnected
  # render, once for the connected one — doubling this DB read when the
  # viewer has no personal timezone set). Mirrors BroadcastEditor.assign_tz/1.
  defp assign_tz(socket) do
    tz = Timezone.viewer_tz(socket)

    socket
    |> assign(:tz, tz)
    |> assign(:tz_label, Timezone.tz_label(tz))
  end

  @impl true
  # handle_params judges the value; only a string can go into the address.
  def handle_event("filter_status", %{"status" => status}, socket) when is_binary(status) do
    {:noreply, push_patch(socket, to: page_url(1, status))}
  end

  def handle_event("filter_status", _params, socket), do: {:noreply, socket}

  attr(:status_filter, :string, required: true)

  # Inside a form: the LiveView client refuses phx-change on a bare input.
  defp status_filter(assigns) do
    ~H"""
    <form id="broadcasts-status-filter" phx-change="filter_status">
      <.select
        name="status"
        value={@status_filter}
        prompt={gettext("All statuses")}
        options={Enum.map(Broadcast.valid_statuses(), &{StatusLabel.broadcast(&1), &1})}
        class="select-sm"
        aria-label={gettext("Status")}
      />
    </form>
    """
  end

  def status_label(status), do: StatusLabel.broadcast(status)

  # Cheap per-row label — no per-broadcast CRM list name lookup (that
  # would mean an N+1 across this whole listing); the details page
  # already resolves the actual list/role names for a single broadcast.
  def source_label(source_type), do: gettext_source(source_type)

  defp gettext_source("crm_list"), do: gettext("CRM list")
  defp gettext_source("user_group"), do: gettext("Roles")
  # Pre-V156 'sent' rows keep their historical source_type value; show a
  # human label rather than the internal identifier.
  defp gettext_source("newsletters_list"), do: gettext("Legacy list")
  defp gettext_source(other), do: other
end
