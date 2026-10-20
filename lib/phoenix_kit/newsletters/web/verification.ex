defmodule PhoenixKit.Newsletters.Web.Verification do
  @moduledoc """
  LiveView that checks the addresses of a broadcast audience.

  The audience is picked the way a broadcast picks it — a CRM list or a set
  of roles — and resolved with the same functions the sender uses
  (`CRMSource.sendable_recipients/1`, `UserGroupSource.sendable_recipients/1`),
  so the page shows exactly the addresses a send would mail. The verdicts come
  from the Emails module's verification engine through
  `PhoenixKit.Newsletters.EmailVerification`; without that module (or with it
  switched off) the page says so instead of failing.

  The whole state lives in the URL (`?source=&list=&roles[]=&status=&page=`),
  so a filtered page can be linked and every change is a `push_patch`.
  Progress of a running batch arrives over PubSub; the table is re-read when
  the batch ends, not on every message.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TableDefault

  import PhoenixKit.Newsletters.Web.Timezone, only: [format_datetime: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.EmailVerification
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.VerificationRows
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @active_batch_states ~w(queued running)
  @terminal_batch_states ~w(done cancelled)
  # How often a running batch re-reads whether the SMTP runner is still online.
  @runner_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      {:ok,
       socket
       |> assign(:page_title, gettext("Address verification"))
       |> assign(:page_subtitle, gettext("Check the addresses of a broadcast audience"))
       |> assign(:page_section, gettext("Newsletters"))
       |> assign(:page_section_path, Paths.broadcasts_index())
       |> assign(:project_title, Settings.get_project_title())
       |> assign(:engine, engine_state())
       |> assign(:queue_configured, EmailVerification.queue_configured?())
       |> assign(:crm_available, CRMSource.available?())
       |> assign(:crm_lists, nil)
       |> assign(:available_roles, nil)
       |> assign(:source, "user_group")
       |> assign(:crm_list_uuid, "")
       |> assign(:role_uuids, [])
       |> assign(:status_filter, "")
       |> assign(:audience_key, nil)
       |> assign(:emails, [])
       |> assign(:rows, [])
       |> assign(:page, 1)
       |> assign(:total_pages, 1)
       |> assign(:total, 0)
       |> assign(:summary, nil)
       |> assign(:batch, nil)
       |> assign(:subscribed_batch, nil)
       |> assign(:smtp_wait, false)
       |> assign(:runner_tick, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{engine: :ready}} = socket) do
    source = parse_source(params["source"], socket.assigns.crm_available)

    socket =
      socket
      |> assign_tz()
      |> assign_audience_options()
      |> assign(:source, source)
      |> assign(
        :crm_list_uuid,
        if(source == "crm_list", do: parse_uuid(params["list"]), else: "")
      )
      |> assign(
        :role_uuids,
        if(source == "user_group", do: parse_roles(params["roles"]), else: [])
      )
      |> assign(:status_filter, VerificationRows.parse_status(params["status"]))

    {:noreply,
     socket
     |> refresh_audience()
     |> load_table(VerificationRows.parse_page(params["page"]))}
  end

  def handle_params(_params, _url, socket), do: {:noreply, assign_tz(socket)}

  @impl true
  def handle_event("select_audience", params, socket) do
    source = parse_source(params["source"], socket.assigns.crm_available)

    query = %{
      "source" => source,
      "list" => if(source == "crm_list", do: params["list"]),
      "roles" => if(source == "user_group", do: parse_roles(params["roles"]))
    }

    {:noreply, push_patch(socket, to: Paths.verification_index(query))}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    %{source: source, crm_list_uuid: list_uuid, role_uuids: role_uuids} = socket.assigns

    {:noreply,
     push_patch(socket,
       to: Paths.verification_index(page_params(source, list_uuid, role_uuids, status))
     )}
  end

  def handle_event("start_batch", _params, %{assigns: %{engine: :ready}} = socket) do
    # The audience and its latest batch are read again: the click may be stale
    # (another tab or a double click started a batch since the page was drawn).
    socket = refresh_audience(socket, force: true)

    cond do
      socket.assigns.emails == [] ->
        {:noreply, put_flash(socket, :error, start_error(:no_emails))}

      batch_active?(socket.assigns.batch) ->
        {:noreply, put_flash(socket, :error, start_error(:already_running))}

      true ->
        {:noreply, start_batch(socket)}
    end
  end

  def handle_event("start_batch", _params, %{assigns: %{engine: :disabled}} = socket) do
    {:noreply, put_flash(socket, :error, start_error(:disabled))}
  end

  def handle_event("start_batch", _params, socket) do
    {:noreply, put_flash(socket, :error, start_error(:unavailable))}
  end

  @impl true
  def handle_info(
        {:email_verify_batch, %{uuid: uuid} = snapshot},
        %{assigns: %{batch: %{uuid: uuid} = batch}} = socket
      ) do
    cond do
      snapshot.state in @terminal_batch_states ->
        fresh = EmailVerification.get_batch(uuid) || Map.merge(batch, progress_of(snapshot))

        {:noreply,
         socket
         |> assign(:batch, fresh)
         |> refresh_smtp_wait()
         |> load_table(socket.assigns.page)}

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
        &EmailVerification.results_for/1
      )

    socket
    |> assign(:rows, rows)
    |> assign(:page, meta.page)
    |> assign(:total_pages, meta.total_pages)
    |> assign(:total, meta.total)
    |> assign(:summary, EmailVerification.summary(socket.assigns.emails))
  end

  ## --- Batches ---

  defp start_batch(socket) do
    {type, ref, title} = batch_source(socket.assigns)
    opts = [title: title, created_by_uuid: current_user_uuid(socket)]

    case EmailVerification.start_batch(socket.assigns.emails, type, ref, opts) do
      {:ok, batch} ->
        socket
        |> track_batch(batch)
        |> load_table(socket.assigns.page)
        |> put_flash(:info, gettext("Verification started"))

      {:error, reason} ->
        put_flash(socket, :error, start_error(reason))
    end
  end

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
  # not online. Only a running batch can wait, so a finished one costs no read.
  defp refresh_smtp_wait(socket) do
    assign(
      socket,
      :smtp_wait,
      batch_active?(socket.assigns.batch) and EmailVerification.smtp_runner_waiting?()
    )
  end

  # The runner can go offline without any batch message arriving, so a running
  # batch re-reads it on a timer (one pending timer at most).
  defp schedule_runner_refresh(%{assigns: %{runner_tick: true}} = socket), do: socket

  defp schedule_runner_refresh(socket) do
    Process.send_after(self(), :refresh_runner, @runner_refresh_ms)
    assign(socket, :runner_tick, true)
  end

  defp subscribe_once(%{assigns: %{subscribed_batch: uuid}} = socket, uuid), do: socket

  defp subscribe_once(socket, uuid) do
    EmailVerification.subscribe_batch(uuid)
    assign(socket, :subscribed_batch, uuid)
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

  defp start_error(:unavailable), do: gettext("The Emails module is not available")
  defp start_error(:disabled), do: gettext("Address verification is switched off")

  defp start_error({:engine_error, _message}),
    do: gettext("The verification failed to start: the Emails module reported an error")

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

  @doc false
  def page_params(source, crm_list_uuid, role_uuids, status) do
    %{"source" => source, "list" => crm_list_uuid, "roles" => role_uuids, "status" => status}
  end
end
