defmodule PhoenixKit.Newsletters.Web.BroadcastEditor do
  @moduledoc """
  LiveView for creating and editing newsletter broadcasts with Markdown editor and live preview.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.PkLink

  # Optional soft dependencies — guarded by Code.ensure_loaded? at runtime
  # Use module atoms directly (not alias) to avoid compile-time warnings
  @email_templates_mod PhoenixKit.Modules.Emails.Templates
  @email_template_mod PhoenixKit.Modules.Emails.Template

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.{Broadcaster, Content, CRMSource}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: DateUtils
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:page_title, gettext("New broadcast"))
        |> assign(
          :page_subtitle,
          gettext("Compose and send a broadcast email to your newsletter list")
        )
        |> assign(:page_section, gettext("Broadcasts"))
        |> assign(:page_section_path, Routes.path("/admin/newsletters/broadcasts"))
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:lists, [])
        |> assign(:templates, [])
        |> assign(:broadcast, nil)
        |> assign(:subject, "")
        |> assign(:source_type, "newsletters_list")
        |> assign(:list_uuid, "")
        |> assign(:crm_available, CRMSource.available?())
        |> assign(:crm_lists, [])
        |> assign(:crm_list_uuid, "")
        |> assign(:preflight, nil)
        |> assign(:crm_list_archived?, false)
        |> assign(:template_uuid, "")
        |> assign(:markdown_content, "")
        |> assign(:preview_html, "")
        |> assign(:scheduled_at, "")
        |> assign(:saving, false)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, %{assigns: %{live_action: :edit}} = socket) do
    lists = Newsletters.list_lists(%{status: "active"})
    crm_lists = CRMSource.list_lists()
    templates = load_templates()
    broadcast = Newsletters.get_broadcast!(id)
    socket = assign_tz(socket)

    {:noreply,
     socket
     |> assign(:lists, lists)
     |> assign(:crm_lists, crm_lists)
     |> assign(:templates, templates)
     |> assign(:page_title, gettext("Edit broadcast"))
     |> assign(:broadcast, broadcast)
     |> assign(:subject, broadcast.subject || "")
     |> assign(:source_type, broadcast.source_type)
     |> assign(:list_uuid, broadcast.list_uuid || "")
     |> assign(:crm_list_uuid, broadcast.crm_list_uuid || "")
     |> assign(:template_uuid, broadcast.template_uuid || "")
     |> assign(:markdown_content, broadcast.markdown_body || "")
     |> assign(
       :preview_html,
       render_preview(broadcast.markdown_body, broadcast.template_uuid, templates)
     )
     |> assign(
       :scheduled_at,
       DateUtils.format_datetime_local(broadcast.scheduled_at, socket.assigns.tz_offset)
     )
     |> assign_preflight()}
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, gettext("Broadcast not found"))
       |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))}
  end

  def handle_params(_params, _url, socket) do
    lists = Newsletters.list_lists(%{status: "active"})
    crm_lists = CRMSource.list_lists()
    templates = load_templates()
    default_template_uuid = default_template_uuid()

    {:noreply,
     socket
     |> assign_tz()
     |> assign(:lists, lists)
     |> assign(:crm_lists, crm_lists)
     |> assign(:templates, templates)
     |> assign(:template_uuid, default_template_uuid || "")}
  end

  @impl true
  def handle_event("validate", params, socket) do
    subject = params["subject"] || socket.assigns.subject
    source_type = params["source_type"] || socket.assigns.source_type
    {list_uuid, crm_list_uuid} = resolve_source_fields(socket.assigns, source_type, params)
    template_uuid = params["template_uuid"] || socket.assigns.template_uuid
    scheduled_at = params["scheduled_at"] || socket.assigns.scheduled_at

    preview_html =
      render_preview(socket.assigns.markdown_content, template_uuid, socket.assigns.templates)

    {:noreply,
     socket
     |> assign(:subject, subject)
     |> assign(:source_type, source_type)
     |> assign(:list_uuid, list_uuid)
     |> assign(:crm_list_uuid, crm_list_uuid)
     |> assign(:template_uuid, template_uuid)
     |> assign(:scheduled_at, scheduled_at)
     |> assign(:preview_html, preview_html)
     |> assign_preflight()}
  end

  @impl true
  def handle_event("save_draft", params, socket) do
    socket = update_assigns_from_params(socket, params)
    save_broadcast(socket, "draft")
  end

  @impl true
  def handle_event("send_now", params, socket) do
    socket = update_assigns_from_params(socket, params)

    case save_broadcast_and_return(socket) do
      {:ok, broadcast} ->
        case Broadcaster.send(broadcast) do
          {:ok, _broadcast} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Broadcast is being sent"))
             |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts/#{broadcast.uuid}"))}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to send: %{reason}", reason: inspect(reason))
             )}
        end

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to save: %{reason}", reason: inspect(reason)))}
    end
  end

  @impl true
  def handle_event("schedule", params, socket) do
    socket = update_assigns_from_params(socket, params)

    case socket.assigns.scheduled_at do
      "" ->
        {:noreply, put_flash(socket, :error, gettext("Please select a schedule date and time"))}

      scheduled_at_str ->
        case DateUtils.parse_datetime_local(scheduled_at_str, socket.assigns.tz_offset) do
          {:ok, scheduled_at} ->
            save_broadcast(socket, "scheduled", %{scheduled_at: scheduled_at})

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Please select a valid schedule date and time"))}
        end
    end
  end

  @impl true
  def handle_info({:editor_content_changed, %{content: content}}, socket) do
    preview_html = render_preview(content, socket.assigns.template_uuid, socket.assigns.templates)

    {:noreply,
     socket
     |> assign(:markdown_content, content)
     |> assign(:preview_html, preview_html)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  # Guard: Emails.Templates is an optional dependency — only call if loaded
  defp load_templates do
    if Code.ensure_loaded?(@email_templates_mod) do
      soft_call(@email_templates_mod, :list_templates, [%{status: "active"}])
    else
      []
    end
  end

  defp default_template_uuid do
    if Code.ensure_loaded?(@email_templates_mod) do
      PhoenixKit.Settings.get_setting("newsletters_default_template")
    else
      nil
    end
  end

  defp update_assigns_from_params(socket, params) do
    source_type = params["source_type"] || socket.assigns.source_type
    {list_uuid, crm_list_uuid} = resolve_source_fields(socket.assigns, source_type, params)

    socket
    |> assign(:subject, params["subject"] || socket.assigns.subject)
    |> assign(:source_type, source_type)
    |> assign(:list_uuid, list_uuid)
    |> assign(:crm_list_uuid, crm_list_uuid)
    |> assign(:template_uuid, params["template_uuid"] || socket.assigns.template_uuid)
    |> assign(:scheduled_at, params["scheduled_at"] || socket.assigns.scheduled_at)
  end

  # Resolves list_uuid/crm_list_uuid from params, but drops whichever one
  # belongs to the *other* source the moment source_type actually changes
  # — otherwise switching from "newsletters list" to "CRM list" (or back)
  # leaves the previous selection's uuid stranded in assigns (and from
  # there, in the saved broadcast row) even though its own field is no
  # longer rendered/editable.
  defp resolve_source_fields(assigns, source_type, params) do
    list_uuid = params["list_uuid"] || assigns.list_uuid
    crm_list_uuid = params["crm_list_uuid"] || assigns.crm_list_uuid

    if source_type != assigns.source_type do
      case source_type do
        "crm_list" -> {"", crm_list_uuid}
        _ -> {list_uuid, ""}
      end
    else
      {list_uuid, crm_list_uuid}
    end
  end

  # Recomputes the CRM preflight breakdown (and whether the selected list
  # is archived) whenever the crm_list selection changes; nil/false for
  # anything else — a newsletters_list source, or crm_list with nothing
  # picked yet.
  defp assign_preflight(
         %{assigns: %{source_type: "crm_list", crm_list_uuid: crm_list_uuid}} = socket
       )
       when is_binary(crm_list_uuid) and crm_list_uuid != "" do
    socket
    |> assign(:preflight, CRMSource.preflight(crm_list_uuid))
    |> assign(:crm_list_archived?, crm_list_archived?(crm_list_uuid))
  end

  defp assign_preflight(socket) do
    socket
    |> assign(:preflight, nil)
    |> assign(:crm_list_archived?, false)
  end

  defp crm_list_archived?(crm_list_uuid) do
    case CRMSource.get_list(crm_list_uuid) do
      %{status: status} -> status != "active"
      nil -> false
    end
  end

  defp save_broadcast(socket, status, extra_attrs \\ %{}) do
    socket = assign(socket, :saving, true)

    attrs =
      Map.merge(
        %{
          subject: socket.assigns.subject,
          source_type: socket.assigns.source_type,
          list_uuid: socket.assigns.list_uuid,
          crm_list_uuid: socket.assigns.crm_list_uuid,
          template_uuid:
            if(socket.assigns.template_uuid == "", do: nil, else: socket.assigns.template_uuid),
          markdown_body: socket.assigns.markdown_content,
          status: status
        },
        extra_attrs
      )

    result =
      case socket.assigns.broadcast do
        nil -> Newsletters.create_broadcast(attrs)
        broadcast -> Newsletters.update_broadcast(broadcast, attrs)
      end

    case result do
      {:ok, broadcast} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:broadcast, broadcast)
         |> put_flash(
           :info,
           gettext("Broadcast saved as %{status}", status: status_label(status))
         )
         |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))}

      {:error, changeset} ->
        errors =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(:error, gettext("Validation failed: %{errors}", errors: errors))}
    end
  end

  defp status_label("draft"), do: gettext("Draft")
  defp status_label("scheduled"), do: gettext("Scheduled")
  defp status_label("sending"), do: gettext("Sending")
  defp status_label("sent"), do: gettext("Sent")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label(other), do: other

  # Gates Send now/Schedule — whichever source is selected must have a
  # target picked (a newsletters list, or a CRM list), and a picked CRM
  # list must not be archived (an archived list would refuse in
  # Broadcaster.send/1 anyway — this just surfaces that up front instead
  # of letting the click fail after a round trip).
  defp recipient_source_missing?(
         %{source_type: "crm_list", crm_list_uuid: crm_list_uuid} = assigns
       ) do
    crm_list_uuid in [nil, ""] or assigns[:crm_list_archived?] == true
  end

  defp recipient_source_missing?(%{list_uuid: list_uuid}) do
    list_uuid in [nil, ""]
  end

  defp save_broadcast_and_return(socket) do
    attrs = %{
      subject: socket.assigns.subject,
      source_type: socket.assigns.source_type,
      list_uuid: socket.assigns.list_uuid,
      crm_list_uuid: socket.assigns.crm_list_uuid,
      template_uuid:
        if(socket.assigns.template_uuid == "", do: nil, else: socket.assigns.template_uuid),
      markdown_body: socket.assigns.markdown_content,
      status: "draft"
    }

    case socket.assigns.broadcast do
      nil -> Newsletters.create_broadcast(attrs)
      broadcast -> Newsletters.update_broadcast(broadcast, attrs)
    end
  end

  defp render_preview(markdown, template_uuid, templates) do
    markdown
    |> Content.render_markdown()
    |> inject_into_template(template_uuid, templates)
  end

  defp inject_into_template(html, template_uuid, templates)
       when is_binary(template_uuid) and template_uuid != "" do
    if Code.ensure_loaded?(PhoenixKit.Modules.Emails.Template) do
      apply_template_if_found(html, template_uuid, templates)
    else
      html
    end
  end

  defp inject_into_template(html, _, _), do: html

  defp template_display_name(template) do
    soft_call(@email_template_mod, :get_translation, [template.display_name, "en"]) ||
      template.name
  end

  defp apply_template_if_found(html, template_uuid, templates) do
    case Enum.find(templates, fn t -> t.uuid == template_uuid end) do
      nil ->
        html

      tmpl ->
        html_body = soft_call(@email_template_mod, :get_translation, [tmpl.html_body, "en"])
        String.replace(html_body, "{{content}}", html)
    end
  end

  # Resolves and assigns the viewer's timezone from handle_params (not
  # mount, which runs twice per connection — once for the disconnected
  # render, once for the connected one — doubling this DB read). Mirrors
  # phoenix_kit_crm's contact_show_live.ex, which resolves the same way
  # from its own handle_params for the same reason.
  defp assign_tz(socket) do
    tz_offset = user_tz_offset(socket)

    socket
    |> assign(:tz_offset, tz_offset)
    |> assign(:tz_label, Settings.get_timezone_label(tz_offset, Settings.get_setting_options()))
  end

  # The viewer's timezone offset — user profile → system setting → "0" (UTC),
  # via core's `PhoenixKit.Utils.Date.get_user_timezone/1`. Drives how the
  # `scheduled_at` datetime-local input is interpreted/displayed (storage
  # is always UTC).
  defp user_tz_offset(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{} = user -> DateUtils.get_user_timezone(user)
      _ -> Settings.get_setting("time_zone", "0")
    end
  rescue
    _ -> "0"
  end

  # Human-readable confirmation of what the typed local time resolves to,
  # shown next to the schedule input so the interpretation is never a guess
  # (e.g. "Sends at 21:58 (UTC+3 (...)) · 18:58 UTC"). `nil` when there's
  # nothing typed yet or the value can't be parsed.
  defp schedule_preview("", _tz_offset, _tz_label), do: nil

  defp schedule_preview(scheduled_at_str, tz_offset, tz_label) do
    with [_date, local_time] <- String.split(scheduled_at_str, "T", parts: 2),
         {:ok, utc_dt} <- DateUtils.parse_datetime_local(scheduled_at_str, tz_offset) do
      gettext("Sends at %{local} (%{tz}) · %{utc} UTC",
        local: String.slice(local_time, 0, 5),
        tz: tz_label,
        utc: Calendar.strftime(utc_dt, "%H:%M")
      )
    else
      _ -> nil
    end
  end

  # Intentional apply/3 — calls optional soft-dependency modules to avoid compile-time warnings
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_call(mod, fun, args), do: apply(mod, fun, args)
end
