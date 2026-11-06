defmodule PhoenixKit.Newsletters.Web.BroadcastDetails do
  @moduledoc """
  LiveView for viewing broadcast details and delivery statistics.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Pagination
  import PhoenixKitWeb.Components.Core.PkLink
  import PhoenixKitWeb.Components.Core.TableDefault

  import PhoenixKit.Newsletters.Web.Timezone, only: [format_datetime: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Access
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Broadcaster
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.Web.Paging
  alias PhoenixKit.Newsletters.Web.SendError
  alias PhoenixKit.Newsletters.Web.StatusLabel
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:broadcast_id, nil)
        # Fallback title for the chrome breadcrumb until the broadcast loads
        # (handle_params overwrites it with the subject) — replaces the old
        # in-content <h1> fallback that was removed with the page header.
        |> assign(:page_title, gettext("Broadcast details"))
        |> assign(:page_subtitle, nil)
        |> assign(:page_section, gettext("Newsletters"))
        |> assign(:page_section_path, Routes.path("/admin/newsletters/broadcasts"))
        |> assign(:project_title, Settings.get_project_title())
        |> assign_new(:current_locale, fn -> nil end)
        |> assign(:broadcast, nil)
        |> assign(:deliveries, [])
        |> assign(:delivery_stats, %{})
        |> assign(:resendable_count, 0)
        |> assign(:unresendable_count, 0)
        |> assign(:page_param, nil)
        |> assign(:page, 1)
        |> assign(:per_page, Paging.per_page())
        |> assign(:total_count, 0)
        |> assign(:total_pages, 1)
        |> assign(:crm_list, nil)
        |> assign(:crm_preflight, nil)
        |> assign(:stale_roles, 0)
        |> assign(:can_start, false)
        |> assign(:attachment_files, [])
        |> assign(:loading, true)
        |> assign(:show_confirm_modal, false)
        |> assign(:confirm_action, nil)
        |> assign(:confirm_target, nil)
        |> assign(:confirm_title, "")
        |> assign(:confirm_message, "")
        |> assign(:can_send, Access.can_send?(Access.scope(socket)))
        |> assign(:can_see_audiences, Access.can_see_audiences?(Access.scope(socket)))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id} = params, _url, socket) do
    {:noreply,
     socket
     |> assign_tz()
     |> assign(:broadcast_id, id)
     |> assign(:page_param, params["page"])
     |> assign(:loading, true)
     |> load_broadcast_data()}
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
  def handle_event("show_confirm", %{"action" => "cancel_broadcast"}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :cancel_broadcast)
     |> assign(:confirm_title, gettext("Cancel broadcast"))
     |> assign(:confirm_message, cancel_message(socket.assigns.broadcast))}
  end

  @impl true
  def handle_event("show_confirm", %{"action" => "retry_send"}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :retry_send)
     |> assign(:confirm_title, gettext("Retry send"))
     |> assign(
       :confirm_message,
       gettext("This will retry sending the broadcast from the beginning.")
     )}
  end

  @impl true
  def handle_event("show_confirm", %{"action" => "resend_failed"}, socket) do
    count = socket.assigns.resendable_count

    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :resend_failed)
     |> assign(:confirm_title, gettext("Resend failed deliveries"))
     |> assign(
       :confirm_message,
       ngettext(
         "This sends the broadcast again to the %{count} recipient whose delivery failed. Nobody else is mailed, and anyone who can no longer receive it is skipped.",
         "This sends the broadcast again to the %{count} recipients whose delivery failed. Nobody else is mailed, and anyone who can no longer receive it is skipped.",
         count,
         count: count
       )
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
        with :ok <- authorize_send(socket), do: cancel_broadcast(socket)

      :retry_send ->
        with :ok <- authorize_retry(socket), do: retry_send(socket)

      :resend_failed ->
        with :ok <- authorize_retry(socket), do: resend_failed(socket)

      _ ->
        {:noreply, socket}
    end
  end

  # Reversible, so no dialog: the broadcast goes back to where it can be fixed.
  @impl true
  def handle_event("back_to_draft", _params, socket) do
    with :ok <- authorize_send(socket), do: back_to_draft(socket)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_broadcast_data()}
  end

  # --- Private ---

  # Cancelling is final, so the dialog says so: there is no way back from it, and
  # a scheduled broadcast has no deliveries yet for it to stop.
  defp cancel_message(%{status: "scheduled"}) do
    gettext("This broadcast will never go out. A cancelled broadcast cannot be edited or sent.")
  end

  defp cancel_message(_broadcast) do
    gettext("This will stop any remaining deliveries. A cancelled broadcast cannot be resumed.")
  end

  defp back_to_draft(socket) do
    case Newsletters.unschedule_broadcast(socket.assigns.broadcast) do
      {:ok, broadcast} ->
        {:noreply,
         push_navigate(socket,
           to: Routes.path("/admin/newsletters/broadcasts/#{broadcast.uuid}/edit")
         )}

      {:error, {:invalid_status, status}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("A broadcast with status %{status} cannot go back to draft.",
             status: status_label(status)
           )
         )
         |> load_broadcast_data()}

      {:error, :not_found} ->
        {:noreply, load_broadcast_data(socket)}
    end
  end

  # Decided by the database, not by this page's copy: see
  # `Newsletters.cancel_broadcast/1`. A refusal reloads, because the usual reason
  # is that the page is out of date.
  defp cancel_broadcast(socket) do
    case Newsletters.cancel_broadcast(socket.assigns.broadcast) do
      {:ok, _broadcast} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Broadcast cancelled"))
         |> load_broadcast_data()}

      {:error, {:invalid_status, status}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("A broadcast with status %{status} cannot be cancelled.",
             status: status_label(status)
           )
         )
         |> load_broadcast_data()}

      {:error, :not_found} ->
        {:noreply, load_broadcast_data(socket)}
    end
  end

  # Cancelling stops a send, so it needs the same `newsletters.send` that
  # starts one.
  defp authorize_send(socket) do
    if Access.can_send?(Access.scope(socket)) do
      :ok
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to send broadcasts"))}
    end
  end

  # Retrying is sending: it needs `newsletters.send`, and for a CRM-list
  # broadcast the CRM module's key too, since the send resolves the list.
  # `confirm_action` takes the action from assigns, but `show_confirm` is a
  # client event, so the check sits here rather than on the button only.
  defp authorize_retry(socket) do
    scope = Access.scope(socket)
    broadcast = socket.assigns.broadcast

    cond do
      not Access.can_send?(scope) ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to send broadcasts"))}

      (broadcast && broadcast.source_type == "crm_list") and not Access.crm_lists?(scope) ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to use CRM lists"))}

      true ->
        :ok
    end
  end

  # Re-reads the row before sending. Both the "failed" gate on the button
  # and Broadcaster.send/1's own status guard are only as fresh as the last
  # page load, so a click from a tab left open since the broadcast was
  # retried elsewhere would hand the guard a stale "failed" struct and drag
  # an already-sending (or already-sent) broadcast back into "sending" with
  # a fresh sent_at — and re-enqueue anyone added to the audience since.
  # Reloading first makes the guard judge the row as it actually is.
  defp retry_send(socket) do
    case Broadcaster.send(Newsletters.get_broadcast!(socket.assigns.broadcast_id)) do
      {:ok, _broadcast} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Broadcast is being sent"))
         |> load_broadcast_data()}

      {:error, reason} ->
        # Reload on refusal too: the usual reason for one is that this
        # page's copy of the broadcast is out of date, so leave the
        # operator looking at the current status rather than the "failed"
        # one they clicked.
        {:noreply,
         socket
         |> put_flash(:error, SendError.message(reason))
         |> load_broadcast_data()}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, gettext("Broadcast not found"))
       |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))}
  end

  # Decided on the locked row, not this page's copy, so unlike `retry_send/1` the
  # struct needs no reload first.
  defp resend_failed(socket) do
    case Broadcaster.resend_failed(socket.assigns.broadcast) do
      {:ok, _broadcast, count} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "Resending %{count} failed delivery",
             "Resending %{count} failed deliveries",
             count,
             count: count
           )
         )
         |> load_broadcast_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, SendError.message(reason))
         |> load_broadcast_data()}
    end
  end

  defp load_broadcast_data(socket) do
    id = socket.assigns.broadcast_id

    try do
      broadcast = Newsletters.get_broadcast_with_template!(id)
      stats = Newsletters.get_delivery_stats(id)
      total = stats |> Map.values() |> Enum.sum()
      {page, offset} = Paging.resolve(socket.assigns.page_param, total)
      {resendable, unresendable} = resend_counts(broadcast, stats)

      # Recipient addresses only with `newsletters.audiences`.
      deliveries =
        if Access.can_see_audiences?(Access.scope(socket)),
          do: Newsletters.list_deliveries(id, %{limit: Paging.per_page(), offset: offset}),
          else: []

      # The CRM list behind a broadcast is resolved only for a viewer who
      # also holds the CRM module's key.
      crm? = Access.crm_lists?(Access.scope(socket))
      crm_list = if crm?, do: CRMSource.get_list(broadcast.crm_list_uuid)

      socket
      |> assign(:broadcast, broadcast)
      |> assign(:deliveries, deliveries)
      |> assign(:delivery_stats, stats)
      |> assign(:resendable_count, resendable)
      |> assign(:unresendable_count, unresendable)
      |> assign(:page, page)
      |> assign(:total_count, total)
      |> assign(:total_pages, Paging.total_pages(total))
      |> assign(:crm_list, crm_list)
      |> assign(:crm_preflight, if(crm?, do: crm_preflight(broadcast)))
      |> assign(:stale_roles, stale_roles(broadcast))
      |> assign(:can_start, can_start?(socket, broadcast, crm?, crm_list))
      |> assign(:attachment_files, load_attachment_files(broadcast.attachments || []))
      |> assign(:loading, false)
      |> assign(:page_title, broadcast.subject)
    rescue
      _ in [Ecto.NoResultsError, Ecto.Query.CastError] ->
        socket
        |> assign(:loading, false)
        |> put_flash(:error, gettext("Broadcast not found"))
        |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))
    end
  end

  # Only a finished broadcast can resend. Failed rows left out of the count stay
  # failed for good, so the page says why rather than leaving the numbers to differ.
  defp resend_counts(%{status: "sent", uuid: uuid}, stats) do
    resendable = Newsletters.count_resendable_deliveries(uuid)
    {resendable, stat_value(stats, "failed") - resendable}
  end

  defp resend_counts(_broadcast, _stats), do: {0, 0}

  defp list_sendable?(%{status: status}), do: status == "active"
  defp list_sendable?(_list), do: true

  defp page_url(page, broadcast_uuid) do
    query = if page > 1, do: "?page=#{page}", else: ""
    Routes.path("/admin/newsletters/broadcasts/#{broadcast_uuid}#{query}")
  end

  defp crm_preflight(%{source_type: "crm_list", crm_list_uuid: crm_list_uuid})
       when is_binary(crm_list_uuid) do
    CRMSource.preflight(crm_list_uuid)
  end

  defp crm_preflight(_broadcast), do: nil

  defp stale_roles(%{source_type: "user_group"} = broadcast) do
    broadcast |> Broadcast.role_uuids() |> UserGroupSource.stale_role_count()
  end

  defp stale_roles(_broadcast), do: 0

  # Whether a send can start from here: the same checks the click would meet, so
  # Retry and Resend are not offered where they can only be refused.
  defp can_start?(socket, %{source_type: "crm_list"}, crm?, crm_list) do
    Access.can_send?(Access.scope(socket)) and crm? and list_sendable?(crm_list)
  end

  defp can_start?(socket, _broadcast, _crm?, _crm_list) do
    Access.can_send?(Access.scope(socket))
  end

  @doc "Display-only role names a `user_group` broadcast targeted — see `Broadcast.role_names_snapshot/1`."
  def role_names_snapshot(broadcast), do: Broadcast.role_names_snapshot(broadcast)

  def status_label(status), do: StatusLabel.broadcast(status)

  def delivery_label(status), do: gettext_delivery(status)

  defp gettext_delivery("pending"), do: gettext("Pending")
  defp gettext_delivery("sent"), do: gettext("Sent")
  defp gettext_delivery("delivered"), do: gettext("Delivered")
  defp gettext_delivery("opened"), do: gettext("Opened")
  defp gettext_delivery("bounced"), do: gettext("Bounced")
  defp gettext_delivery("failed"), do: gettext("Failed")
  defp gettext_delivery("blocked"), do: gettext("Blocked")
  defp gettext_delivery(other), do: other

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

  defp delivery_badge_class(status) do
    case status do
      "pending" -> "badge-ghost"
      "sent" -> "badge-info"
      "delivered" -> "badge-success"
      "opened" -> "badge-primary"
      "bounced" -> "badge-warning"
      "failed" -> "badge-error"
      "blocked" -> "badge-neutral"
      _ -> "badge-ghost"
    end
  end

  # A delivery is addressable by a core User (role broadcast), shown by the
  # address its mail goes to, or a snapshotted recipient_email (CRM-list
  # broadcast) — see Delivery's moduledoc.
  def recipient_display(%{user: %User{} = user}) do
    UserGroupSource.delivery_address(user) || user.email
  end

  def recipient_display(%{user: %{email: email}}), do: email
  def recipient_display(%{recipient_email: email}) when is_binary(email), do: email
  def recipient_display(%{user_uuid: user_uuid}), do: user_uuid

  # `Broadcast.attachments` is a plain uuid list — resolved here to a list
  # of `{uuid, file_or_nil}` pairs (one per uuid, `nil` when it no longer
  # resolves to a file — e.g. deleted from Storage after the broadcast was
  # saved) for the read-only chip list's filename/size, in the same order
  # the broadcast sent them in. Mirrors BroadcastEditor.load_attachment_files/1.
  defp load_attachment_files([]), do: []

  defp load_attachment_files(uuids) do
    files_by_uuid = uuids |> Storage.get_files() |> Map.new(&{&1.uuid, &1})
    Enum.map(uuids, &{&1, Map.get(files_by_uuid, &1)})
  end

  defp format_file_size(bytes), do: Format.bytes(bytes, decimals: 1, unknown: "0 B")

  defp stat_value(stats, key) do
    Map.get(stats, key, 0)
  end

  # Cumulative, as on the list: what was delivered was sent, and what was opened
  # was delivered. Counted from the rows rather than the broadcast's counters,
  # because a provider reports an open every time one happens.
  defp sent_total(stats), do: delivered_total(stats) + stat_value(stats, "sent") + bounced(stats)
  defp delivered_total(stats), do: stat_value(stats, "delivered") + stat_value(stats, "opened")
  defp bounced(stats), do: stat_value(stats, "bounced")

  defp template_display_name(template, locale), do: Layout.display_name(template, locale)
end
