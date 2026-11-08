defmodule PhoenixKit.Newsletters.Web.BroadcastEditor do
  @moduledoc """
  LiveView for creating and editing newsletter broadcasts with Markdown editor and live preview.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Newsletters

  alias PhoenixKit.Newsletters.{
    Access,
    Broadcast,
    Broadcaster,
    Content,
    CRMSource,
    Layout,
    Layouts,
    Render,
    UserGroupSource
  }

  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.Web.FormErrors
  alias PhoenixKit.Newsletters.Web.LanguageOptions
  alias PhoenixKit.Newsletters.Web.SendError
  alias PhoenixKit.Newsletters.Web.StatusLabel
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: DateUtils
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  # Non-blocking warning threshold for the combined size of a broadcast's
  # attachments — most inbox providers cap total message size well above
  # this, but large attachments slow delivery and hit the base64-encoding
  # inflation (~33%) DeliveryWorker applies. Doesn't block send/schedule.
  @attachments_size_warning_bytes 7 * 1024 * 1024

  # What the preflight depends on, and all it depends on.
  @source_fields [:source_type, :crm_list_uuid, :role_uuids]

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      scope = Access.scope(socket)
      # CRM lists only for a viewer who also holds the CRM module's key.
      crm_available = Access.crm_lists?(scope)

      socket =
        socket
        |> assign(:page_title, gettext("New broadcast"))
        |> assign(
          :page_subtitle,
          gettext("Compose and send a broadcast email to your newsletter list")
        )
        |> assign(:page_section, gettext("Newsletters"))
        |> assign(:page_section_path, Paths.broadcasts_index())
        |> assign(:page_crumbs, [])
        |> assign(:project_title, Settings.get_project_title())
        |> assign_new(:current_locale, fn -> nil end)
        |> assign(:templates, [])
        |> assign(:broadcast, nil)
        |> assign(:subject, "")
        |> assign(:source_type, if(crm_available, do: "crm_list", else: "user_group"))
        |> assign(:crm_available, crm_available)
        |> assign(:can_send, Access.can_send?(scope))
        |> assign(:crm_lists, [])
        |> assign(:crm_list_uuid, "")
        |> assign(:available_roles, [])
        |> assign(:role_uuids, [])
        |> assign(:preflight, nil)
        |> assign(:crm_list_archived?, false)
        |> assign(:stranded_crm_list, nil)
        |> assign(:template_uuid, "")
        |> assign(:preview_locale, nil)
        |> assign(:preview_languages, [])
        |> assign(:markdown_content, "")
        |> assign(:preview_html, "")
        |> assign(:preview_signature, nil)
        |> assign(:scheduled_at, "")
        |> assign(:sending, false)
        |> assign(:attachments, [])
        |> assign(:attachment_files, [])
        |> assign(:show_media_selector, false)
        # Normally supplied by PhoenixKit's admin on_mount hook. Defaulted
        # here so the template can reference it as `@phoenix_kit_current_user`
        # rather than `assigns[:phoenix_kit_current_user]` — the `assigns[...]`
        # form is untracked, which re-renders the media picker (and re-runs
        # the enabled-buckets query in its `update/2`) on every keystroke in
        # this form.
        |> assign_new(:phoenix_kit_current_user, fn -> nil end)

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
    case Newsletters.get_broadcast!(id) do
      %Broadcast{status: "draft"} = broadcast ->
        {:noreply, load_draft(socket, broadcast)}

      # The details page offers Edit on a draft only, and this form saves as a
      # draft. Open on anything else, it would take a sent or cancelled broadcast
      # back to the start.
      %Broadcast{} = broadcast ->
        {:noreply, leave_for_details(socket, broadcast.uuid)}
    end
  rescue
    _ in [Ecto.NoResultsError, Ecto.Query.CastError] ->
      {:noreply, leave_for_list(socket)}
  end

  def handle_params(_params, _url, socket) do
    crm_lists = crm_lists(socket)
    templates = load_templates(nil)
    default_template_uuid = Layouts.default_layout_uuid()

    {:noreply,
     socket
     |> assign_tz()
     |> assign_preview_languages()
     |> assign_preview_signature(%Broadcast{})
     |> assign(:crm_lists, crm_lists)
     |> assign(:templates, templates)
     |> assign(:available_roles, UserGroupSource.list_roles())
     |> assign(:template_uuid, default_template_uuid || "")}
  end

  # The body comes from the form like every other field. The editor also reports
  # key presses, but a mouse paste, a drag and a reconnect's form recovery press no
  # key, and only this param carries what they did.
  @impl true
  def handle_event("validate", params, socket) do
    previous_source = Map.take(socket.assigns, @source_fields)
    markdown_content = params["editor_content"] || socket.assigns.markdown_content
    subject = params["subject"] || socket.assigns.subject
    source_type = params["source_type"] || socket.assigns.source_type
    crm_list_uuid = resolve_crm_list_uuid(socket.assigns, source_type, params)
    role_uuids = resolve_role_uuids(source_type, params)
    template_uuid = params["template_uuid"] || socket.assigns.template_uuid
    scheduled_at = params["scheduled_at"] || socket.assigns.scheduled_at
    attachments = resolve_attachments(socket.assigns, params)
    # Only a language the picker offers: every new value would otherwise be
    # a new locale key in core's override-lookup cache.
    preview_locale =
      if params["preview_locale"] in socket.assigns.preview_languages,
        do: params["preview_locale"],
        else: socket.assigns.preview_locale

    preview_html =
      render_preview(
        markdown_content,
        template_uuid,
        socket.assigns.templates,
        preview_locale,
        subject,
        signature: socket.assigns[:preview_signature]
      )

    {:noreply,
     socket
     |> assign(:markdown_content, markdown_content)
     |> assign(:subject, subject)
     |> assign(:source_type, source_type)
     |> assign(:crm_list_uuid, crm_list_uuid)
     |> assign(:role_uuids, role_uuids)
     |> assign(:template_uuid, template_uuid)
     |> assign(:scheduled_at, scheduled_at)
     |> assign(:preview_locale, preview_locale)
     |> assign(:preview_html, preview_html)
     |> assign_attachments(attachments)
     |> refresh_preflight(previous_source)}
  end

  # Single submit entry point, branched on the submitter button's
  # name="action" value (LiveView includes the submitter's name/value in
  # phx-submit params). All three actions used to be separate events, with
  # Send now / Schedule as `type="button"` + phx-click — but a phx-click
  # event carries NO form data, so `update_assigns_from_params/2` saw an
  # empty map and `resolve_role_uuids/2` (deliberately params-authoritative
  # for checkbox semantics) wiped the selected roles to `[]`, failing every
  # user_group send with "select at least one role". Routing all three
  # through form submit means every action gets the full serialized form.
  @impl true
  def handle_event("submit", params, socket) do
    case params["action"] do
      "send_now" -> handle_event("send_now", params, socket)
      "schedule" -> handle_event("schedule", params, socket)
      _ -> handle_event("save_draft", params, socket)
    end
  end

  @impl true
  def handle_event("save_draft", params, socket) do
    socket = update_assigns_from_params(socket, params)

    with :ok <- authorize_source(socket) do
      save_broadcast(socket, "draft", draft_schedule(socket))
    end
  end

  @impl true
  def handle_event("send_now", params, socket) do
    socket = update_assigns_from_params(socket, params)

    with :ok <- authorize_send(socket),
         :ok <- authorize_source(socket),
         :ok <- require_body(socket) do
      send_now(socket)
    end
  end

  @impl true
  def handle_event("schedule", params, socket) do
    socket = update_assigns_from_params(socket, params)

    with :ok <- authorize_send(socket),
         :ok <- authorize_source(socket),
         :ok <- require_body(socket) do
      schedule(socket)
    end
  end

  @impl true
  def handle_event("open_attachments_picker", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  @impl true
  def handle_event("remove_attachment", %{"uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:attachments, Enum.reject(socket.assigns.attachments, &(&1 == uuid)))
     |> load_attachment_files()}
  end

  # Two steps. This event saves the draft and answers at once; the send itself
  # runs from `handle_info({:send_now, _}, _)`, after the answer. Resolving and
  # enqueueing a large audience can outlast the 30 seconds the browser waits for
  # an event's answer, and then the browser reloads: on `/new` that was an empty
  # form while the first send went on, and a second click mailed everyone twice.
  # Now the page is already on the draft's own address, so a reload opens the
  # draft, whose row lock refuses a second send. The draft is kept even when the
  # send is refused, which is what makes the next click update it, not insert
  # another. "Send now" is not scheduled, so a time the draft kept is cleared.
  defp send_now(socket) do
    case persist(socket, Map.put(broadcast_attrs(socket, "draft"), :scheduled_at, nil)) do
      {:ok, broadcast} ->
        send(self(), {:send_now, broadcast})

        {:noreply,
         socket
         |> assign(:broadcast, broadcast)
         |> assign(:sending, true)
         |> patch_to_draft(broadcast)}

      {:error, reason} ->
        {:noreply, save_refused(socket, reason)}
    end
  end

  defp patch_to_draft(%{assigns: %{live_action: :new}} = socket, broadcast),
    do: push_patch(socket, to: Paths.broadcast_edit(broadcast.uuid))

  defp patch_to_draft(socket, _broadcast), do: socket

  defp schedule(socket) do
    case socket.assigns.scheduled_at do
      "" ->
        {:noreply, put_flash(socket, :error, gettext("Please select a schedule date and time"))}

      scheduled_at_str ->
        case DateUtils.parse_datetime_local(scheduled_at_str, socket.assigns.tz) do
          {:ok, scheduled_at} ->
            schedule_at(socket, scheduled_at)

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Please select a valid schedule date and time"))}
        end
    end
  end

  # A time already gone would go out on the next tick, to everyone, under a
  # message saying it had been scheduled.
  defp schedule_at(socket, scheduled_at) do
    if DateTime.after?(scheduled_at, DateUtils.utc_now()) do
      save_broadcast(socket, "scheduled", %{scheduled_at: scheduled_at})
    else
      {:noreply, put_flash(socket, :error, gettext("Please choose a time in the future"))}
    end
  end

  # A draft keeps a time typed into it, for whoever opens it next, or nothing
  # when the field holds nothing usable.
  defp draft_schedule(socket) do
    case DateUtils.parse_datetime_local(socket.assigns.scheduled_at, socket.assigns.tz) do
      {:ok, scheduled_at} -> %{scheduled_at: scheduled_at}
      {:error, _reason} -> %{scheduled_at: nil}
    end
  end

  defp require_body(socket) do
    if blank?(socket.assigns.markdown_content) do
      {:noreply, put_flash(socket, :error, SendError.message(:blank_body))}
    else
      :ok
    end
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  @impl true
  def handle_info({:send_now, broadcast}, socket) do
    case Broadcaster.send(broadcast) do
      {:ok, _broadcast} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Broadcast is being sent"))
         |> push_navigate(to: Paths.broadcast_show(broadcast.uuid))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:sending, false)
         |> assign(:broadcast, broadcast)
         |> put_flash(:error, SendError.message(reason))}
    end
  end

  def handle_info({:editor_content_changed, %{content: content}}, socket) do
    preview_html =
      render_preview(
        content,
        socket.assigns.template_uuid,
        socket.assigns.templates,
        socket.assigns.preview_locale,
        socket.assigns.subject,
        signature: socket.assigns[:preview_signature]
      )

    {:noreply,
     socket
     |> assign(:markdown_content, content)
     |> assign(:preview_html, preview_html)}
  end

  # MediaSelectorModal reports back the FULL current selection (not a
  # delta) — see its moduledoc. Attachments are LiveView-owned state,
  # deliberately not threaded through form params like role_uuids/
  # crm_list_uuid: there's no form field to wipe on an unrelated submit,
  # so the role_uuids-wipe bug (nl#26) doesn't apply here.
  @impl true
  def handle_info({:media_selected, file_uuids}, socket) do
    {:noreply,
     socket
     |> assign(:attachments, file_uuids)
     |> assign(:show_media_selector, false)
     |> load_attachment_files()}
  end

  @impl true
  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, :show_media_selector, false)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp load_draft(socket, broadcast) do
    crm_lists = crm_lists(socket)
    templates = load_templates(broadcast.template_uuid)

    socket =
      socket |> assign_tz() |> assign_preview_languages() |> assign_preview_signature(broadcast)

    socket
    |> assign(:crm_lists, crm_lists)
    |> assign(:templates, templates)
    |> assign(:page_title, gettext("Edit"))
    |> assign(:page_crumbs, [
      %{
        label: broadcast.subject,
        path: Paths.broadcast_show(broadcast.uuid)
      }
    ])
    |> assign(:broadcast, broadcast)
    |> assign(:subject, broadcast.subject || "")
    |> assign(:source_type, broadcast.source_type)
    |> assign(:crm_list_uuid, broadcast.crm_list_uuid || "")
    |> assign(:available_roles, UserGroupSource.list_roles())
    |> assign(:role_uuids, Broadcast.role_uuids(broadcast))
    |> assign(:template_uuid, broadcast.template_uuid || "")
    |> assign(:markdown_content, broadcast.markdown_body || "")
    |> assign(
      :preview_html,
      render_preview(
        broadcast.markdown_body,
        broadcast.template_uuid,
        templates,
        socket.assigns.preview_locale,
        broadcast.subject,
        signature: socket.assigns[:preview_signature]
      )
    )
    |> assign(
      :scheduled_at,
      DateUtils.format_datetime_local(broadcast.scheduled_at, socket.assigns.tz)
    )
    |> assign(:attachments, broadcast.attachments || [])
    |> load_attachment_files()
    |> assign_preflight()
  end

  defp leave_for_details(socket, uuid) do
    socket
    |> put_flash(:error, gettext("Only a draft can be edited"))
    |> push_navigate(to: Paths.broadcast_show(uuid))
  end

  defp leave_for_list(socket) do
    socket
    |> put_flash(:error, gettext("Broadcast not found"))
    |> push_navigate(to: Paths.broadcasts_index())
  end

  # A refused save: the row changed under this form, so there is nothing to fix
  # here and the operator goes to the broadcast as it is now.
  defp save_refused(socket, %Ecto.Changeset{} = changeset) do
    put_flash(socket, :error, validation_error(changeset))
  end

  defp save_refused(socket, {:invalid_status, _status}) do
    leave_for_details(socket, socket.assigns.broadcast.uuid)
  end

  defp save_refused(socket, :not_found), do: leave_for_list(socket)

  # Sending, scheduling and retrying need `newsletters.send`; the buttons are
  # hidden without it, and a crafted submit is refused here.
  defp authorize_send(socket) do
    if Access.can_send?(Access.scope(socket)) do
      :ok
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to send broadcasts"))}
    end
  end

  # A CRM list is saved, sent or previewed only for a viewer who also holds
  # the CRM module's key — the form never offers one otherwise, so this
  # refuses a crafted `source_type`/`crm_list_uuid` and an existing CRM-list
  # broadcast opened by someone without it.
  defp authorize_source(%{assigns: %{source_type: "crm_list"}} = socket) do
    if Access.crm_lists?(Access.scope(socket)) do
      :ok
    else
      {:noreply, put_flash(socket, :error, gettext("You don't have permission to use CRM lists"))}
    end
  end

  defp authorize_source(_socket), do: :ok

  defp crm_lists(socket) do
    if Access.crm_lists?(Access.scope(socket)), do: CRMSource.list_lists(), else: []
  end

  # The active layouts, plus the broadcast's own when it has been archived
  # since — otherwise the select would silently show "standard layout" and
  # the next save would clear the broadcast's choice.
  defp load_templates(current_uuid) do
    active = Layouts.list_layouts(status: "active")

    case current_uuid && Enum.find(active, &(&1.uuid == current_uuid)) do
      nil ->
        case current_uuid && Layouts.get_layout(current_uuid) do
          %Layout{} = archived -> active ++ [archived]
          _ -> active
        end

      _found ->
        active
    end
  end

  # The signature of the profile a send would go out through, which the preview
  # shows where the send puts it. Read once per page, not per keystroke.
  defp assign_preview_signature(socket, broadcast) do
    signature =
      case DeliveryWorker.resolve_send_profile(broadcast) do
        %{signature_html: html} -> html
        nil -> nil
      end

    assign(socket, :preview_signature, signature)
  end

  # The preview's language picker: the site's languages, the preview
  # starting in the site's content language.
  defp assign_preview_languages(socket) do
    languages = LanguageOptions.site_languages()

    socket
    |> assign(:preview_languages, languages)
    |> assign(:preview_locale, socket.assigns.preview_locale || List.first(languages))
  end

  defp update_assigns_from_params(socket, params) do
    source_type = params["source_type"] || socket.assigns.source_type
    crm_list_uuid = resolve_crm_list_uuid(socket.assigns, source_type, params)
    role_uuids = resolve_role_uuids(source_type, params)

    socket
    |> assign(:markdown_content, params["editor_content"] || socket.assigns.markdown_content)
    |> assign(:subject, params["subject"] || socket.assigns.subject)
    |> assign(:source_type, source_type)
    |> assign(:crm_list_uuid, crm_list_uuid)
    |> assign(:role_uuids, role_uuids)
    |> assign(:template_uuid, params["template_uuid"] || socket.assigns.template_uuid)
    |> assign(:scheduled_at, params["scheduled_at"] || socket.assigns.scheduled_at)
    |> assign_attachments(resolve_attachments(socket.assigns, params))
  end

  # The form carries the attachments as well as the picker setting them, so that
  # form recovery after a reconnect brings them back: without them a remount
  # emptied a new broadcast's list (and reverted an edited one), and Send now then
  # mailed everyone without the files. Only a form that says it holds the list
  # speaks for it, and only well-formed uuids, as many as a broadcast takes.
  defp resolve_attachments(_assigns, %{"attachments_sent" => _} = params) do
    params
    |> Map.get("attachments", [])
    |> List.wrap()
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.uniq()
    |> Enum.take(Broadcast.max_attachments())
  end

  defp resolve_attachments(assigns, _params), do: assigns.attachments

  # Storage is read only when the list really changed, not on every keystroke.
  defp assign_attachments(%{assigns: %{attachments: same}} = socket, same), do: socket

  defp assign_attachments(socket, attachments) do
    socket |> assign(:attachments, attachments) |> load_attachment_files()
  end

  # Drops the CRM list selection the moment source_type switches away from
  # "crm_list" — otherwise switching to "Roles" leaves the previous list
  # selection stranded in assigns (and from there, in the saved broadcast
  # row) even though the field is no longer rendered/editable.
  #
  # Only a list the picker offers, or the one this draft already has: the rest are
  # operational segments, which must not become a broadcast's audience through a
  # crafted value.
  defp resolve_crm_list_uuid(assigns, source_type, params) do
    crm_list_uuid = params["crm_list_uuid"] || assigns.crm_list_uuid

    if source_type == "crm_list" and selectable_list?(assigns, crm_list_uuid),
      do: crm_list_uuid,
      else: ""
  end

  defp selectable_list?(%{broadcast: %{crm_list_uuid: uuid}}, uuid), do: true

  defp selectable_list?(assigns, crm_list_uuid) do
    Enum.any?(assigns.crm_lists, &(&1.uuid == crm_list_uuid))
  end

  # role_uuids doesn't fit the params[field] || assigns.field fallback the
  # other source fields use — an unchecked checkbox simply never appears
  # in `params` at all, so falling back to the old assign on a missing key
  # would make unchecking a role a no-op. The role checkboxes' `checked`
  # attribute is bound to `@role_uuids`, so LiveView's phx-change always
  # serializes the form's actual current checkbox state; params is
  # authoritative here, defaulting to [] rather than merging with the old
  # value. Not the selected source at all (fieldset unrendered) means no
  # roles, same "drop the stale field" reasoning as resolve_crm_list_uuid/3.
  #
  # Only well-formed uuids: a crafted value would be saved, then raise in every
  # query that reads it, on every page that shows this broadcast.
  defp resolve_role_uuids("user_group", params) do
    params
    |> Map.get("role_uuids", [])
    |> List.wrap()
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
  end

  defp resolve_role_uuids(_source_type, _params), do: []

  # The preflight reads the whole audience, so only a change of audience pays for
  # it. Every other field in this form reports on phx-change too.
  defp refresh_preflight(socket, previous_source) do
    if Map.take(socket.assigns, @source_fields) == previous_source,
      do: socket,
      else: assign_preflight(socket)
  end

  # Recomputes the CRM preflight breakdown (and whether the selected list
  # is archived) whenever the crm_list selection changes, or the
  # user_group preflight whenever the role selection changes; nil/false
  # for anything else — either source with nothing picked yet.
  defp assign_preflight(
         %{assigns: %{source_type: "crm_list", crm_list_uuid: crm_list_uuid, crm_available: true}} =
           socket
       )
       when is_binary(crm_list_uuid) and crm_list_uuid != "" do
    # One fetch feeds both the archived warning and the stranded-option fallback.
    list = CRMSource.get_list(crm_list_uuid)

    socket
    |> assign(:preflight, CRMSource.preflight(crm_list_uuid))
    |> assign(:crm_list_archived?, archived?(list))
    |> assign(:stranded_crm_list, stranded_crm_list(list, socket.assigns.crm_lists))
  end

  defp assign_preflight(%{assigns: %{source_type: "user_group", role_uuids: role_uuids}} = socket)
       when role_uuids != [] do
    socket
    |> assign(:preflight, UserGroupSource.preflight(role_uuids))
    |> assign(:crm_list_archived?, false)
    |> assign(:stranded_crm_list, nil)
  end

  defp assign_preflight(socket) do
    socket
    |> assign(:preflight, nil)
    |> assign(:crm_list_archived?, false)
    |> assign(:stranded_crm_list, nil)
  end

  # Resolves `:attachments` (a plain uuid list — see Broadcast.attachments'
  # moduledoc note) to `:attachment_files`, a list of `{uuid, file_or_nil}`
  # pairs — ONE per uuid, in the same order they were picked/saved in —
  # for the chip list. `Storage.get_files/1` silently drops any uuid with
  # no matching row, which would otherwise make a stale/deleted attachment
  # invisible in the picker with no way to remove it specifically; zipping
  # back against the full uuid list keeps every entry, `nil` file marking
  # the ones that didn't resolve ("missing file" chip in the template).
  # The saved `:attachments` list itself is never derived from this
  # resolution (save_broadcast/3 reads socket.assigns.attachments
  # directly) — a transient Storage hiccup here can make a chip render as
  # missing, but can never silently drop a real uuid from what gets saved.
  defp load_attachment_files(socket) do
    uuids = socket.assigns.attachments

    entries =
      case uuids do
        [] ->
          []

        uuids ->
          files_by_uuid = uuids |> Storage.get_files() |> Map.new(&{&1.uuid, &1})
          Enum.map(uuids, &{&1, Map.get(files_by_uuid, &1)})
      end

    assign(socket, :attachment_files, entries)
  end

  defp attachments_total_bytes(entries) do
    Enum.reduce(entries, 0, fn
      {_uuid, %Storage.File{size: size}}, acc -> size + acc
      {_uuid, nil}, acc -> acc
    end)
  end

  defp attachments_size_warning?(entries) do
    attachments_total_bytes(entries) > @attachments_size_warning_bytes
  end

  defp format_file_size(bytes), do: Format.bytes(bytes, decimals: 1, unknown: "0 B")

  # A uuid that no longer resolves to a list at all counts as not archived — it
  # resolves to nobody, which Broadcaster.send/1 refuses on its own.
  defp archived?(%{status: status}), do: status != "active"
  defp archived?(nil), do: false

  # The currently selected list when it is absent from the picker's
  # options (archived, or subscribable turned off after this broadcast
  # picked it). Rendered as a disabled <option selected> — without that
  # the browser falls back to the placeholder and the next save silently
  # resets crm_list_uuid.
  defp stranded_crm_list(nil, _crm_lists), do: nil

  defp stranded_crm_list(list, crm_lists) do
    if Enum.any?(crm_lists, &(&1.uuid == list.uuid)), do: nil, else: list
  end

  defp save_broadcast(socket, status, extra_attrs) do
    case persist(socket, Map.merge(broadcast_attrs(socket, status), extra_attrs)) do
      {:ok, broadcast} ->
        {:noreply,
         socket
         |> assign(:broadcast, broadcast)
         |> put_flash(
           :info,
           gettext("Broadcast saved as %{status}", status: StatusLabel.broadcast(status))
         )
         |> push_navigate(to: Paths.broadcasts_index())}

      {:error, reason} ->
        {:noreply, save_refused(socket, reason)}
    end
  end

  defp broadcast_attrs(socket, status) do
    %{
      subject: socket.assigns.subject,
      source_type: socket.assigns.source_type,
      crm_list_uuid: socket.assigns.crm_list_uuid,
      source_params: role_group_source_params(socket.assigns),
      template_uuid:
        if(socket.assigns.template_uuid == "", do: nil, else: socket.assigns.template_uuid),
      markdown_body: socket.assigns.markdown_content,
      attachments: socket.assigns.attachments,
      status: status
    }
  end

  # An existing broadcast is written only while the database still has it as a
  # draft; this form's copy is as old as the tab.
  # A new broadcast records who wrote it; an edit leaves the author as it is.
  defp persist(socket, attrs) do
    case socket.assigns.broadcast do
      nil -> Newsletters.create_broadcast(Map.put(attrs, :created_by_user_uuid, author(socket)))
      broadcast -> Newsletters.update_draft(broadcast, attrs)
    end
  end

  defp author(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _none -> nil
    end
  end

  defp validation_error(changeset) do
    gettext("Validation failed: %{errors}", errors: FormErrors.summary(changeset))
  end

  # Snapshots the CURRENTLY-live name of each selected role uuid alongside
  # it — resolution always goes through role_uuids (stable), the snapshot
  # is display-only (see Broadcast.role_names_snapshot/1's moduledoc).
  # @available_roles was loaded once for this LiveView session, so a role
  # renamed by someone else mid-edit won't be reflected here — an
  # accepted, narrow race; refreshing it defeats the point of loading it
  # once per session like @crm_lists already does.
  defp role_group_source_params(%{source_type: "user_group"} = assigns) do
    names =
      assigns.available_roles
      |> Enum.filter(&(&1.uuid in assigns.role_uuids))
      |> Enum.map(& &1.name)

    %{"role_uuids" => assigns.role_uuids, "role_names_snapshot" => names}
  end

  defp role_group_source_params(_assigns), do: %{}

  # Gates Send now/Schedule — whichever source is selected must have a
  # target picked (a newsletters list, a CRM list, or at least one role),
  # and a picked CRM list must not be archived (an archived list would
  # refuse in Broadcaster.send/1 anyway — this just surfaces that up
  # front instead of letting the click fail after a round trip).
  defp recipient_source_missing?(
         %{source_type: "crm_list", crm_list_uuid: crm_list_uuid} = assigns
       ) do
    crm_list_uuid in [nil, ""] or assigns[:crm_list_archived?] == true
  end

  defp recipient_source_missing?(%{source_type: "user_group", role_uuids: role_uuids}) do
    role_uuids == []
  end

  # Unreachable in normal flow (source_type is always "crm_list" or
  # "user_group" — see mount/1's default and the picker's own options),
  # but fails closed rather than crashing if it ever isn't.
  defp recipient_source_missing?(_assigns), do: true

  # Send now only: a scheduled send can gain an audience before its time.
  defp nobody_to_send_to?(%{preflight: %{sendable: 0}}), do: true
  defp nobody_to_send_to?(_assigns), do: false

  # The email as a reader of `locale` gets it — the same Render a send
  # uses, with the site's variables — and with the recipient's own placeholders
  # ({{name}}, {{email}}) left visible, since there is no recipient yet. A sample
  # unsubscribe address is bound, so the author sees the line a send would add,
  # and `:signature` is the send profile's, placed as a send places it.
  # Empty until there is a body, so the "appears as you type" hint shows.
  @doc false
  def render_preview(markdown, template_uuid, templates, locale, subject, opts \\ []) do
    if is_binary(markdown) and String.trim(markdown) != "" do
      layout = Enum.find(templates, &(&1.uuid == template_uuid))
      site = Render.site_variables()
      subject = Render.subject(subject || "", layout, locale, site)

      markdown
      |> Content.render_markdown()
      |> Render.html(
        layout,
        Map.put(site, "unsubscribe_url", Render.preview_unsubscribe_url()),
        locale: locale,
        subject: subject,
        signature: Keyword.get(opts, :signature)
      )
    else
      ""
    end
  end

  # The picker's lists, after the draft's own list when the picker no longer
  # offers it (see the template), as a disabled option that stays selected.
  defp crm_list_options(crm_lists, stranded) do
    stranded_option =
      if stranded,
        do: [
          [
            key: gettext("%{name} (no longer selectable)", name: stranded.name),
            value: stranded.uuid,
            disabled: true
          ]
        ],
        else: []

    stranded_option ++
      Enum.map(crm_lists, fn list ->
        {ngettext(
           "%{name} (%{count} member)",
           "%{name} (%{count} members)",
           list.subscriber_count,
           name: list.name,
           count: list.subscriber_count
         ), list.uuid}
      end)
  end

  defp template_display_name(template, locale) do
    name = Layout.display_name(template, locale)
    if template.status == "archived", do: gettext("%{name} (archived)", name: name), else: name
  end

  # Resolves and assigns the viewer's timezone from handle_params (not
  # mount, which runs twice per connection — once for the disconnected
  # render, once for the connected one — doubling this DB read). Mirrors
  # phoenix_kit_crm's contact_show_live.ex, which resolves the same way
  # from its own handle_params for the same reason.
  #
  # Resolution and label formatting live in Web.Timezone, shared with the
  # broadcasts list, details and list-members views so all four render
  # times identically; the label lookup there also avoids loading every
  # role just to name one zone.
  defp assign_tz(socket) do
    tz = Timezone.viewer_tz(socket)

    socket
    |> assign(:tz, tz)
    |> assign(:tz_label, Timezone.tz_label(tz))
  end

  # Human-readable confirmation of what the typed local time resolves to,
  # shown next to the schedule input so the interpretation is never a guess
  # (e.g. "Sends at 21:58 (UTC+3 (...)) · 18:58 UTC"). `nil` when there's
  # nothing typed yet or the value can't be parsed. Exported (still
  # undocumented, same as this module's other small helpers) so tests can
  # call it directly.
  def schedule_preview("", _tz, _tz_label), do: nil

  # With the date: a slip of a month or a year is what this line is there to show.
  # Written as every other time on these pages is (`Timezone.format_datetime/2`),
  # in the site's formats, so the line reads like the list it will appear in.
  def schedule_preview(scheduled_at_str, tz, tz_label) do
    case DateUtils.parse_datetime_local(scheduled_at_str, tz) do
      {:ok, utc_dt} ->
        gettext("Sends at %{local} (%{tz}) · %{utc} UTC",
          local: Timezone.format_datetime(utc_dt, tz),
          tz: tz_label,
          utc: Timezone.format_datetime(utc_dt, "0")
        )

      {:error, _reason} ->
        nil
    end
  end
end
