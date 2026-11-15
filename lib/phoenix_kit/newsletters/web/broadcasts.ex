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

  # The status filter, the page and its size live in the query string, so a
  # filtered page is a real URL. The size is the person's own, remembered across
  # the admin's lists (`PhoenixKitWeb.PageSize`).
  use PhoenixKitWeb.Live.UrlState,
    params:
      [
        status_filter: [
          default: "",
          url_key: "status",
          in: ["" | Broadcast.valid_statuses()]
        ],
        page: [default: 1, cast: :integer, min: 1]
      ] ++ PhoenixKitWeb.PageSize.url_params()

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:page_title, gettext("Newsletters"))
        |> assign(:page_subtitle, gettext("Create and manage email broadcasts"))
        |> assign(:project_title, Settings.get_project_title())
        # :status_filter, :page and :per_page come from the URL, assigned by
        # UrlState before mount: assigning them here would lose a shared link's.
        |> assign(:broadcasts, [])
        |> assign(:total_count, 0)
        |> assign(:total_pages, 1)
        |> PhoenixKitWeb.PageSize.mount()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  # UrlState's own hook has already put the URL's state in the assigns, and
  # judged it (a status that exists, a page and a size in bounds), by the time
  # this runs: on the first render and on every patch.
  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket |> assign_tz() |> load_broadcasts()}
  end

  # The list loads in handle_params/3, which runs after every change too.
  @impl true
  def handle_url_state(_state, socket), do: socket

  defp load_broadcasts(socket) do
    %{status_filter: status, per_page: per_page, page: requested} = socket.assigns
    total = Newsletters.count_broadcasts(%{status: status})
    {page, offset} = Paging.resolve(requested, total, per_page)

    socket =
      socket
      |> assign(
        :broadcasts,
        Newsletters.list_broadcasts(%{status: status, limit: per_page, offset: offset})
      )
      |> assign(:page, page)
      |> assign(:total_count, total)
      |> assign(:total_pages, Paging.total_pages(total, per_page))

    # A page past the end is clamped above. Replace the URL once, so a shared
    # link does not keep a page the list does not have.
    if page == requested do
      socket
    else
      push_patch(socket, to: url_state_path(socket, page: page), replace: true)
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
  # UrlState drops a status that does not exist; only a string gets that far.
  def handle_event("filter_status", %{"status" => status}, socket) when is_binary(status) do
    {:noreply, push_url_state(socket, status_filter: status)}
  end

  def handle_event("filter_status", _params, socket), do: {:noreply, socket}

  # Saved for the person and applied to every list; the page goes back to 1.
  def handle_event("change_per_page", params, socket),
    do: {:noreply, PhoenixKitWeb.PageSize.handle_change(params, socket)}

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
