defmodule PhoenixKit.Newsletters.Web.Verification do
  @moduledoc """
  LiveView that checks the addresses of a broadcast audience.

  The audience is picked the way a broadcast picks it — a CRM list or a set
  of roles — and resolved with the same functions the sender uses
  (`CRMSource.sendable_recipients/1`, `UserGroupSource.sendable_recipients/1`),
  so the page shows exactly the addresses a send would mail. The verdicts come
  from the host's verification engine (`PhoenixKit.Newsletters.VerificationEngine`)
  through `PhoenixKit.Newsletters.EmailVerification`; without an engine (or with it
  switched off) the page says so instead of failing.

  The whole state lives in the URL (`?source=&list=&roles=&status=&page=&per_page=`,
  roles comma-separated), through `PhoenixKitWeb.Live.UrlState`, so a filtered
  page can be linked and every change is a patch. The page size is the person's
  own, remembered across the admin's lists (`PhoenixKitWeb.PageSize`).
  Progress of a running batch arrives over PubSub; the table is re-read when
  the batch ends, not on every message.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Pagination
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.TableDefault

  import PhoenixKit.Newsletters.Web.Timezone, only: [format_datetime: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Access
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.EmailVerification
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.VerificationRows
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # The `url_*` assigns hold the audience and the filter as the URL spells them;
  # handle_params/3 judges them into `source`, `crm_list_uuid`, `role_uuids` and
  # `status_filter`, and writes the judged values back so the next URL is clean.
  use PhoenixKitWeb.Live.UrlState,
    params:
      [
        url_source: [default: "", url_key: "source", in: ["", "user_group", "crm_list"]],
        url_list: [default: "", url_key: "list"],
        url_roles: [default: "", url_key: "roles"],
        url_status: [
          default: "",
          url_key: "status",
          in: ["" | VerificationRows.statuses()]
        ],
        page: [default: 1, cast: :integer, min: 1]
      ] ++ PhoenixKitWeb.PageSize.url_params()

  @active_batch_states ~w(queued running)
  @terminal_batch_states ~w(done cancelled)
  # How often a running batch re-reads whether the SMTP runner is still online.
  @runner_refresh_ms 10_000

  # The page lists every address of an audience, so it needs
  # `newsletters.audiences` (at mount and on every event); CRM lists are
  # offered only to a viewer who also holds the CRM module's key.
  @impl true
  def mount(_params, _session, socket) do
    cond do
      not Newsletters.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Newsletters module is not enabled"))
         |> push_navigate(to: Routes.path("/admin"))}

      not Access.can_see_audiences?(Access.scope(socket)) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You don't have permission to see broadcast recipients"))
         |> push_navigate(to: Paths.broadcasts_index())}

      true ->
        {:ok, mount_page(socket)}
    end
  end

  defp mount_page(socket) do
    socket
    |> assign(:page_title, gettext("Address verification"))
    |> assign(:page_subtitle, gettext("Check the addresses of a broadcast audience"))
    |> assign(:page_section, gettext("Newsletters"))
    |> assign(:page_section_path, Paths.broadcasts_index())
    |> assign(:project_title, Settings.get_project_title())
    |> assign(:engine, engine_state())
    |> assign(:queue_configured, EmailVerification.queue_configured?())
    |> assign(:crm_available, Access.crm_lists?(Access.scope(socket)))
    |> assign(:crm_lists, nil)
    |> assign(:available_roles, nil)
    |> assign(:source, "user_group")
    |> assign(:crm_list_uuid, "")
    |> assign(:role_uuids, [])
    |> assign(:status_filter, "")
    |> assign(:audience_key, nil)
    |> assign(:emails, [])
    |> assign(:rows, [])
    # :page, :per_page and the url_* assigns come from the URL, assigned by
    # UrlState before mount: assigning them here would lose a shared link's.
    |> assign(:total_pages, 1)
    |> assign(:total, 0)
    |> assign(:summary, nil)
    |> assign(:batch, nil)
    |> assign(:subscribed_batches, MapSet.new())
    |> assign(:starting, false)
    |> assign(:starting_audience, nil)
    |> assign(:smtp_wait, false)
    |> assign(:settings_path, nil)
    |> assign(:runner_tick, false)
    |> PhoenixKitWeb.PageSize.mount()
  end

  # A link from before roles were comma-separated (`roles[]=…`) moves once to
  # the current form: left as it is, its `roles[]` would ride along in every
  # later URL as an unknown key, and Plug lets the last `roles` key win.
  # The path is the one this request used, so a locale segment stays, and the
  # page and its size come along.
  @impl true
  def handle_params(%{"roles" => [_ | _] = roles} = params, uri, socket) do
    {:noreply, push_patch(socket, to: legacy_roles_path(params, roles, uri), replace: true)}
  end

  # UrlState's own hook has already put the URL's state in the assigns by the
  # time this runs, on the first render and on every patch.
  def handle_params(_params, _url, %{assigns: %{engine: :ready}} = socket) do
    %{url_source: url_source, url_list: url_list, url_roles: url_roles} = socket.assigns
    source = parse_source(url_source, socket.assigns.crm_available)
    crm_list_uuid = if source == "crm_list", do: parse_uuid(url_list), else: ""
    role_uuids = if source == "user_group", do: parse_roles(url_roles), else: []
    status = VerificationRows.parse_status(socket.assigns.url_status)

    socket =
      socket
      |> assign_tz()
      |> assign_audience_options()
      |> assign(:source, source)
      |> assign(:crm_list_uuid, crm_list_uuid)
      |> assign(:role_uuids, role_uuids)
      |> assign(:status_filter, status)
      |> assign(:url_source, source)
      |> assign(:url_list, crm_list_uuid)
      |> assign(:url_roles, Enum.join(role_uuids, ","))
      |> assign(:url_status, status)

    requested = socket.assigns.page

    socket =
      socket
      |> refresh_audience()
      |> load_table(requested)

    # A page past the end is clamped above. Replace the URL once, so a shared
    # link does not keep a page the list does not have.
    socket =
      if socket.assigns.page == requested do
        socket
      else
        push_patch(socket, to: url_state_path(socket, page: socket.assigns.page), replace: true)
      end

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket), do: {:noreply, assign_tz(socket)}

  # The page loads in handle_params/3, which runs after every change too.
  @impl true
  def handle_url_state(_state, socket), do: socket

  @impl true
  def handle_event(event, params, socket) do
    if Access.can_see_audiences?(Access.scope(socket)) do
      verification_event(event, params, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to see broadcast recipients"))}
    end
  end

  # A new audience starts without a filter, on its first page.
  defp verification_event("select_audience", params, socket) do
    source = parse_source(params["source"], socket.assigns.crm_available)

    {:noreply,
     push_url_state(socket,
       url_source: source,
       url_list: if(source == "crm_list", do: parse_uuid(params["list"]), else: ""),
       url_roles:
         if(source == "user_group", do: Enum.join(parse_roles(params["roles"]), ","), else: ""),
       url_status: ""
     )}
  end

  defp verification_event("filter_status", %{"status" => status}, socket)
       when is_binary(status) do
    {:noreply, push_url_state(socket, url_status: status)}
  end

  defp verification_event("filter_status", _params, socket), do: {:noreply, socket}

  # Saved for the person and applied to every list; the page goes back to 1.
  defp verification_event("change_per_page", params, socket),
    do: {:noreply, PhoenixKitWeb.PageSize.handle_change(params, socket)}

  defp verification_event("start_batch", _params, %{assigns: %{engine: :ready}} = socket) do
    case engine_state() do
      :ready -> start_ready_batch(socket)
      state -> verification_event("start_batch", %{}, assign(socket, :engine, state))
    end
  end

  defp verification_event("start_batch", _params, %{assigns: %{engine: :disabled}} = socket) do
    {:noreply, put_flash(socket, :error, start_error(:disabled))}
  end

  defp verification_event("start_batch", _params, socket) do
    {:noreply, put_flash(socket, :error, start_error(:unavailable))}
  end

  defp start_ready_batch(socket) do
    # The audience and its latest batch are read again: the click may be stale
    # (another tab or a double click started a batch since the page was drawn).
    socket = refresh_audience(socket, force: true)

    cond do
      socket.assigns.emails == [] ->
        {:noreply, put_flash(socket, :error, start_error(:no_emails))}

      batch_active?(socket.assigns.batch) or socket.assigns.starting ->
        {:noreply, put_flash(socket, :error, start_error(:already_running))}

      true ->
        {:noreply, start_batch(socket)}
    end
  end

  # The engine stores every item of the batch before it answers, which takes
  # seconds for a large audience, so the call runs in a task: the page keeps
  # answering and the button stays disabled until `handle_async/3` has the batch.
  @impl true
  def handle_async(:start_batch, {:ok, {:ok, batch}}, socket) do
    {:noreply,
     socket
     |> assign(:starting, false)
     |> follow_started_batch(batch)
     |> put_flash(:info, gettext("Verification started"))}
  end

  def handle_async(:start_batch, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:starting, false) |> put_flash(:error, start_error(reason))}
  end

  def handle_async(:start_batch, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:starting, false)
     |> put_flash(:error, start_error({:engine_error, nil}))}
  end

  @impl true
  def handle_info(
        {:email_verify_batch, %{uuid: uuid} = snapshot},
        %{assigns: %{batch: %{uuid: uuid} = batch}} = socket
      ) do
    cond do
      batch.state in @terminal_batch_states ->
        {:noreply, socket}

      snapshot.state in @terminal_batch_states ->
        fresh = EmailVerification.get_batch(uuid) || Map.merge(batch, progress_of(snapshot))

        {:noreply,
         socket
         |> assign(:batch, fresh)
         |> refresh_smtp_wait()
         |> load_table(socket.assigns.page)
         |> load_summary()}

      # Workers run in parallel, so a snapshot can arrive after a newer one.
      snapshot.processed < batch.processed ->
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, :batch, Map.merge(batch, progress_of(snapshot)))}
    end
  end

  def handle_info(:refresh_runner, socket) do
    socket = socket |> assign(:runner_tick, false) |> refresh_smtp_wait()

    if connected?(socket) and batch_active?(socket.assigns.batch) do
      {:noreply, schedule_runner_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## --- State ---

  defp engine_state do
    cond do
      not EmailVerification.available?() -> :unavailable
      not EmailVerification.enabled?() -> :disabled
      true -> :ready
    end
  end

  defp assign_tz(socket) do
    tz = Timezone.viewer_tz(socket)

    socket
    |> assign(:tz, tz)
    |> assign(:tz_label, Timezone.tz_label(tz))
  end

  # The pickers' options are read once per LiveView, not on every patch.
  defp assign_audience_options(%{assigns: %{available_roles: nil}} = socket) do
    socket
    |> assign(:available_roles, UserGroupSource.list_roles())
    |> assign(
      :crm_lists,
      if(socket.assigns.crm_available, do: CRMSource.list_active_lists(), else: [])
    )
  end

  defp assign_audience_options(socket), do: socket

  defp parse_source(source, _crm_available) when source == "user_group", do: source
  defp parse_source(source, true) when source == "crm_list", do: source
  defp parse_source(_source, true), do: "crm_list"
  defp parse_source(_source, false), do: "user_group"

  # A uuid from the URL is cast before it reaches a query, which raises on garbage.
  defp parse_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> ""
    end
  end

  defp parse_uuid(_value), do: ""

  # The request's own path, not one rebuilt from `Paths`: that would resolve
  # the locale again and can drop the segment the visitor is actually on.
  defp legacy_roles_path(params, roles, uri) do
    path =
      case URI.parse(uri) do
        %URI{path: path} when is_binary(path) and path != "" -> path
        _ -> Paths.verification_index()
      end

    query =
      ~w(source list status page per_page fit)
      |> Map.new(fn key -> {key, binary_param(params[key])} end)
      |> Map.put("roles", Enum.join(parse_roles(roles), ","))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case query do
      empty when map_size(empty) == 0 -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end

  defp binary_param(value) when is_binary(value) and value != "", do: value
  defp binary_param(_value), do: nil

  # Comma-separated in the URL; a list from the form's checkboxes or an old link.
  # Spaces around a comma are ignored, so a hand-edited link still selects.
  defp parse_roles(roles) when is_binary(roles) do
    roles |> String.split(",") |> Enum.map(&String.trim/1) |> parse_roles()
  end

  defp parse_roles(roles) when is_list(roles) do
    roles |> Enum.map(&parse_uuid/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp parse_roles(_roles), do: []

  # Resolves the audience again only when it changed (or when forced): the
  # status filter and the page are patches over the same addresses.
  defp refresh_audience(socket, opts \\ []) do
    key =
      {socket.assigns.source, socket.assigns.crm_list_uuid, Enum.sort(socket.assigns.role_uuids)}

    if key == socket.assigns.audience_key and not Keyword.get(opts, :force, false) do
      socket
    else
      emails = resolve_emails(socket.assigns)

      socket
      |> assign(:audience_key, key)
      |> assign(:emails, emails)
      |> load_batch()
      |> load_summary()
    end
  end

  defp resolve_emails(%{source: "crm_list", crm_list_uuid: uuid}) when uuid != "" do
    uuid |> CRMSource.sendable_recipients() |> Enum.map(& &1.email)
  end

  defp resolve_emails(%{source: "user_group", role_uuids: [_ | _] = role_uuids}) do
    role_uuids |> UserGroupSource.sendable_recipients() |> Enum.map(& &1.email)
  end

  defp resolve_emails(_assigns), do: []

  defp load_table(socket, page) do
    {rows, meta} =
      VerificationRows.table(
        socket.assigns.emails,
        socket.assigns.status_filter,
        page,
        &EmailVerification.statuses_for/1,
        &EmailVerification.results_for/1,
        socket.assigns.per_page
      )

    socket
    |> assign(:rows, rows)
    |> assign(:page, meta.page)
    |> assign(:total_pages, meta.total_pages)
    |> assign(:total, meta.total)
  end

  # The counts cover the whole audience, so they change only when the audience
  # does or a batch settles verdicts. A page or filter patch re-reads the table
  # and leaves them alone: that would be a status read of every address on each
  # click.
  defp load_summary(socket) do
    assign(socket, :summary, EmailVerification.summary(socket.assigns.emails))
  end

  ## --- Batches ---

  defp start_batch(socket) do
    {type, ref, title} = batch_source(socket.assigns)
    opts = [title: title, created_by_uuid: current_user_uuid(socket)]

    emails = socket.assigns.emails

    socket
    |> assign(:starting, true)
    |> assign(:starting_audience, socket.assigns.audience_key)
    |> start_async(:start_batch, fn -> EmailVerification.start_batch(emails, type, ref, opts) end)
  end

  # The audience picker stays live while the engine stores the batch. If it moved
  # on, the page shows another audience and this batch is not its own:
  # `load_batch/1` finds it again when the operator comes back.
  defp follow_started_batch(
         %{assigns: %{audience_key: key, starting_audience: key}} = socket,
         batch
       ) do
    socket
    |> track_batch(batch)
    |> load_table(socket.assigns.page)
    |> load_summary()
  end

  defp follow_started_batch(socket, _batch), do: socket

  # The batch's source: what `source_type` / `source_ref` the engine stores it
  # under, and a title for the engine's own listings. Roles go in as a digest of
  # the sorted uuids (a ref is capped at 255 characters, a role set is not).
  defp batch_source(%{source: "crm_list"} = assigns) do
    {"newsletters_crm_list", assigns.crm_list_uuid, list_name(assigns)}
  end

  defp batch_source(%{source: "user_group"} = assigns) do
    {"newsletters_user_group", roles_ref(assigns.role_uuids), roles_title(assigns)}
  end

  @doc false
  @spec roles_ref([String.t()]) :: String.t()
  def roles_ref(role_uuids) do
    digest =
      :sha256
      |> :crypto.hash(role_uuids |> Enum.uniq() |> Enum.sort() |> Enum.join(","))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "roles:" <> digest
  end

  defp list_name(%{crm_list_uuid: uuid}) do
    case CRMSource.get_list(uuid) do
      nil -> nil
      list -> list.name
    end
  end

  defp roles_title(%{available_roles: roles, role_uuids: role_uuids}) do
    (roles || [])
    |> Enum.filter(&(&1.uuid in role_uuids))
    |> Enum.map_join(", ", & &1.name)
    |> String.slice(0, 250)
    |> case do
      "" -> nil
      title -> title
    end
  end

  defp load_batch(%{assigns: %{emails: []}} = socket), do: assign(socket, :batch, nil)

  defp load_batch(socket) do
    {type, ref, _title} = batch_source(socket.assigns)

    case EmailVerification.latest_batch(type, ref) do
      nil -> assign(socket, :batch, nil)
      batch -> track_batch(socket, batch)
    end
  end

  # Subscribes once per batch, and only while it can still change. The batch is
  # read again after the subscription: one that finished between the read that
  # found it and the subscribe would otherwise leave the page following a
  # batch whose last message it never got.
  defp track_batch(socket, batch) do
    if connected?(socket) and batch.state in @active_batch_states do
      socket = subscribe_once(socket, batch.uuid)

      socket
      |> assign(:batch, EmailVerification.get_batch(batch.uuid) || batch)
      |> refresh_smtp_wait()
      |> schedule_runner_refresh()
    else
      socket
      |> assign(:batch, batch)
      |> refresh_smtp_wait()
    end
  end

  # Whether the progress should say that SMTP is waiting for a runner that is
  # not online, and where the engine's settings page is (the hint links there).
  # Only a running batch can wait, so a finished one costs no read.
  defp refresh_smtp_wait(socket) do
    waiting = batch_active?(socket.assigns.batch) and EmailVerification.smtp_runner_waiting?()

    socket
    |> assign(:smtp_wait, waiting)
    |> assign(:settings_path, if(waiting, do: EmailVerification.settings_path()))
  end

  # The runner can go offline without any batch message arriving, so a running
  # batch re-reads it on a timer (one pending timer at most).
  defp schedule_runner_refresh(%{assigns: %{runner_tick: true}} = socket), do: socket

  defp schedule_runner_refresh(socket) do
    Process.send_after(self(), :refresh_runner, @runner_refresh_ms)
    assign(socket, :runner_tick, true)
  end

  defp subscribe_once(socket, uuid) do
    if MapSet.member?(socket.assigns.subscribed_batches, uuid) do
      socket
    else
      EmailVerification.subscribe_batch(uuid)
      update(socket, :subscribed_batches, &MapSet.put(&1, uuid))
    end
  end

  defp progress_of(snapshot),
    do: Map.take(snapshot, [:state, :processed, :total, :counts, :awaiting_smtp])

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp start_error(:no_emails), do: gettext("There are no sendable addresses to verify")

  defp start_error(:too_many_emails) do
    gettext("The audience is too large for one batch (at most %{max} addresses)",
      max: EmailVerification.max_batch_size()
    )
  end

  defp start_error(:already_running),
    do: gettext("A verification of this audience is already running")

  defp start_error(:unavailable), do: gettext("The address verification engine is not available")
  defp start_error(:disabled), do: gettext("Address verification is switched off")

  defp start_error({:engine_error, _message}),
    do: gettext("The verification failed to start: the verification engine reported an error")

  defp start_error(_reason), do: gettext("Could not start the verification")

  ## --- Presentation ---

  @doc false
  def batch_active?(%{state: state}), do: state in @active_batch_states
  def batch_active?(_batch), do: false

  # Addresses past the DNS step that wait for the SMTP stage; none on an engine
  # without it (its batches have no such field).
  @doc false
  def awaiting_smtp(batch), do: Map.get(batch, :awaiting_smtp) || 0

  @doc false
  def percent(%{total: total, processed: processed}) when total > 0,
    do: min(round(processed * 100 / total), 100)

  def percent(_batch), do: 0

  @doc false
  def status_label(:valid), do: gettext("Valid")
  def status_label(:invalid), do: gettext("Invalid")
  def status_label(:temp), do: gettext("Temporary problem")
  def status_label(:not_sure), do: gettext("Not sure")
  def status_label(:unchecked), do: gettext("Not checked")
  def status_label(:mx_ok), do: gettext("Domain OK (no SMTP)")
  def status_label(:smtp_pending), do: gettext("Waiting for SMTP")

  @doc false
  def status_badge_class(:valid), do: "badge-success"
  def status_badge_class(:invalid), do: "badge-error"
  def status_badge_class(:temp), do: "badge-warning"
  def status_badge_class(:mx_ok), do: "badge-info"
  def status_badge_class(:not_sure), do: "badge-ghost"
  def status_badge_class(:smtp_pending), do: "badge-accent badge-outline"
  def status_badge_class(:unchecked), do: "badge-ghost badge-outline"

  @doc false
  def reason_label(nil), do: ""
  def reason_label("syntax"), do: gettext("Invalid syntax")
  def reason_label("bad_tld"), do: gettext("Unknown top-level domain")
  def reason_label("disposable"), do: gettext("Disposable domain")
  def reason_label("no_mx"), do: gettext("The domain accepts no mail")
  def reason_label("dns_error"), do: gettext("DNS error")
  def reason_label("job_failed"), do: gettext("Verification failed, will need a re-run")
  def reason_label("smtp_disabled"), do: gettext("Mailbox not probed (SMTP check is off)")
  def reason_label("smtp_unavailable"), do: gettext("Mailbox not probed (SMTP unavailable)")
  def reason_label("smtp_error"), do: gettext("Mailbox not probed (SMTP error)")
  def reason_label("smtp_pending"), do: gettext("Waiting for the SMTP check")
  def reason_label("catch_all"), do: gettext("Catch-all")
  def reason_label("mailbox_unknown"), do: gettext("Mailbox does not exist")
  def reason_label("mailbox_full"), do: gettext("Mailbox is full")
  def reason_label("greylisted"), do: gettext("Greylisted")
  def reason_label("smtp_blocked"), do: gettext("Mail server blocked the check")
  def reason_label("smtp_timeout"), do: gettext("SMTP check timed out")
  def reason_label("smtp_connect_failed"), do: gettext("Could not connect to the mail server")
  def reason_label("mail_from_rejected"), do: gettext("Mail server rejected the sender")
  def reason_label("smtp_ok"), do: gettext("Mailbox confirmed by the SMTP check")
  def reason_label("smtp_reset"), do: gettext("Mail server reset the connection")
  def reason_label(other), do: other

  @doc false
  def reason_of(%{result: %{} = result}), do: reason_label(Map.get(result, :reason))
  def reason_of(_row), do: ""

  @doc false
  def flag?(%{result: %{} = result}, flag), do: Map.get(result, flag) == true
  def flag?(_row, _flag), do: false

  @doc false
  def checked_at(%{result: %{} = result}, tz),
    do: format_datetime(Map.get(result, :checked_at), tz)

  def checked_at(_row, _tz), do: "-"
end
