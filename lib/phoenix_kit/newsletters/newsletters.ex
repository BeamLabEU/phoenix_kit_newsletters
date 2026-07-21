defmodule PhoenixKit.Newsletters do
  @moduledoc """
  Newsletters module — email broadcasts and subscription management.

  Provides newsletter list management, broadcast creation with Markdown editor,
  per-recipient delivery tracking via Oban workers, and unsubscribe flow.

  Requires the Emails module to be enabled for full functionality.
  Template integration is optional — works without Emails installed.
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def version, do: unquote(Mix.Project.config()[:version])

  @impl PhoenixKit.Module
  def module_key, do: "newsletters"

  @impl PhoenixKit.Module
  def module_name, do: "Newsletters"

  @impl PhoenixKit.Module
  def required_modules, do: ["emails"]

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("newsletters_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("newsletters_enabled", true, "newsletters")
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("newsletters_enabled", false, "newsletters")
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "newsletters",
      label: "Newsletters",
      icon: "📨",
      description: "Email broadcasts and subscription management"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    alias PhoenixKit.Newsletters.Web

    [
      Tab.new!(
        id: :admin_newsletters,
        label: "Newsletters",
        icon: "hero-megaphone",
        path: "newsletters/broadcasts",
        priority: 520,
        level: :admin,
        permission: "newsletters",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        subtab_indent: "pl-4",
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_broadcasts,
        label: "Broadcasts",
        icon: "hero-paper-airplane",
        path: "newsletters/broadcasts",
        priority: 521,
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        match: :prefix,
        live_view: {Web.Broadcasts, :index},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_broadcast_new,
        label: "New broadcast",
        path: "newsletters/broadcasts/new",
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        visible: false,
        live_view: {Web.BroadcastEditor, :new},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_broadcast_edit,
        label: "Edit broadcast",
        path: "newsletters/broadcasts/:id/edit",
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        visible: false,
        live_view: {Web.BroadcastEditor, :edit},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_broadcast_details,
        label: "Broadcast details",
        path: "newsletters/broadcasts/:id",
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        visible: false,
        live_view: {Web.BroadcastDetails, :show},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def user_dashboard_tabs do
    alias PhoenixKit.Newsletters.CRMSource

    [
      Tab.new!(
        id: :dashboard_newsletters_preferences,
        label: "Email preferences",
        icon: "hero-envelope",
        # Absolute — this is NOT one of user_dashboard_tabs/0's own
        # auto-registered routes (those all require an authenticated
        # scope). The preference center lives on its own live_session
        # (PhoenixKit.Newsletters.Web.Routes) that stays reachable by a
        # signed token with no login at all, so it has no `live_view`
        # field here — clicking this nav entry is a normal cross-session
        # navigation to that separately-registered route, not a
        # dashboard-internal live_patch.
        path: "/newsletters/preferences",
        priority: 700,
        group: :account,
        visible: fn _scope -> CRMSource.available?() end,
        gettext_backend: PhoenixKit.Newsletters.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_newsletters]

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKit.Newsletters.Web.Routes

  alias PhoenixKit.Newsletters.{
    Broadcast,
    Broadcaster,
    Content,
    Delivery
  }

  import Ecto.Query

  # ============================================================================
  # Broadcasts
  # ============================================================================

  def list_broadcasts(filters \\ %{}) do
    Broadcast
    |> maybe_filter_broadcast_status(filters)
    |> preload([:list])
    |> order_by([b], desc: b.inserted_at)
    |> apply_pagination(filters)
    |> repo().all()
  end

  def get_broadcast!(uuid) do
    Broadcast
    |> preload([:list])
    |> repo().get!(uuid)
  end

  @doc """
  Returns a broadcast with optional template loaded.

  If Emails module is available and the broadcast has a template_uuid,
  the template is loaded and put into `broadcast.template`. Otherwise
  `broadcast.template` is nil.
  """
  def get_broadcast_with_template!(uuid) do
    broadcast = get_broadcast!(uuid)
    maybe_load_template(broadcast)
  end

  def create_broadcast(attrs) do
    %Broadcast{}
    |> Broadcast.changeset(attrs)
    |> repo().insert()
  end

  def update_broadcast(%Broadcast{} = broadcast, attrs) do
    broadcast
    |> Broadcast.changeset(attrs)
    |> repo().update()
  end

  def delete_broadcast(%Broadcast{status: "draft"} = broadcast), do: repo().delete(broadcast)
  def delete_broadcast(_), do: {:error, :cannot_delete_non_draft}

  def render_broadcast_html(%Broadcast{} = broadcast) do
    Content.render_markdown_strict(broadcast.markdown_body)
  end

  # ============================================================================
  # Deliveries
  # ============================================================================

  def list_deliveries(broadcast_uuid, filters \\ %{}) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> maybe_filter_delivery_status(filters)
    |> preload(:user)
    |> order_by([d], desc: d.inserted_at)
    |> apply_pagination(filters)
    |> repo().all()
  end

  def get_delivery_stats(broadcast_uuid) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> group_by([d], d.status)
    |> select([d], {d.status, count(d.uuid)})
    |> repo().all()
    |> Map.new()
  end

  def update_delivery_status(%Delivery{} = delivery, status, attrs \\ %{}) do
    delivery
    |> Delivery.changeset(Map.merge(attrs, %{status: status}))
    |> repo().update()
  end

  def find_delivery_by_message_id(message_id) do
    Delivery
    |> where([d], d.message_id == ^message_id)
    |> preload(:broadcast)
    |> repo().one()
  end

  # ============================================================================
  # Scheduled Processing
  # ============================================================================

  def process_scheduled_broadcasts do
    repair_stuck_sending_broadcasts()

    now = PhoenixKit.Utils.Date.utc_now()

    broadcasts =
      Broadcast
      |> where([b], b.status == "scheduled" and b.scheduled_at <= ^now)
      |> order_by([b], asc: b.scheduled_at)
      |> repo().all()

    count =
      Enum.reduce(broadcasts, 0, fn broadcast, acc ->
        case Broadcaster.send(broadcast) do
          {:ok, _} -> acc + 1
          {:error, reason} -> handle_scheduled_send_failure(broadcast, reason, acc)
        end
      end)

    {:ok, count}
  end

  @doc false
  # Repair sweep for broadcasts stuck in "sending": DeliveryWorker's
  # per-delivery status transition (update_delivery_result/5) normally
  # flips a broadcast to "sent" itself the moment every one of its
  # deliveries has left Delivery's only non-terminal status (see
  # Delivery.non_terminal_broadcast_uuids_query/0), but any broadcast that
  # finished its deliveries *before* that finalize check existed (or whose
  # final worker crashed after the delivery-status write but before the
  # broadcast flip — the two are two statements, not one) is stuck
  # forever: nothing else ever re-checks it. Called from
  # process_scheduled_broadcasts/0 so it rides the same periodic tick.
  #
  # A single batch UPDATE, not a per-row loop — the WHERE clause matches
  # against each row's status at statement execution time, so it can
  # never double-transition a broadcast a concurrent DeliveryWorker
  # commit has already flipped (that row simply won't match "sending"
  # anymore) and never needs its own transaction.
  def repair_stuck_sending_broadcasts do
    {count, _} =
      Broadcast
      |> where([b], b.status == "sending")
      |> where([b], b.uuid not in subquery(Delivery.non_terminal_broadcast_uuids_query()))
      |> repo().update_all(set: [status: "sent"])

    if count > 0 do
      Logger.info("Newsletters: repaired #{count} broadcast(s) stuck in \"sending\"")
    end

    count
  end

  # Non-retryable: the CRM list won't become active again on its own, so
  # leaving status "scheduled" here would make every future tick re-fetch
  # this broadcast and log the same failure forever. Terminal "failed"
  # removes it from process_scheduled_broadcasts/0's `status == "scheduled"`
  # query. The list's own current status (already surfaced on
  # broadcast_details whenever it isn't "active") is the visible reason —
  # no separate reason field needed.
  defp handle_scheduled_send_failure(broadcast, {:crm_list_not_active, _status} = reason, acc) do
    Logger.error("Scheduled broadcast #{broadcast.uuid} failed permanently: #{inspect(reason)}")

    case update_broadcast(broadcast, %{status: "failed"}) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to mark broadcast as failed: #{inspect(changeset.errors)}")
    end

    acc
  end

  defp handle_scheduled_send_failure(broadcast, reason, acc) do
    Logger.warning("Failed to send scheduled broadcast #{broadcast.uuid}: #{inspect(reason)}")
    acc
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp maybe_load_template(%{template_uuid: nil} = broadcast), do: broadcast

  defp maybe_load_template(%{template_uuid: _uuid} = broadcast) do
    if Code.ensure_loaded?(PhoenixKit.Modules.Emails.Template) do
      template = repo().get(PhoenixKit.Modules.Emails.Template, broadcast.template_uuid)
      Map.put(broadcast, :template, template)
    else
      broadcast
    end
  end

  defp maybe_filter_broadcast_status(query, %{status: status})
       when is_binary(status) and status != "" do
    where(query, [b], b.status == ^status)
  end

  defp maybe_filter_broadcast_status(query, _), do: query

  defp maybe_filter_delivery_status(query, %{status: status})
       when is_binary(status) and status != "" do
    where(query, [d], d.status == ^status)
  end

  defp maybe_filter_delivery_status(query, _), do: query

  defp apply_pagination(query, filters) do
    limit = Map.get(filters, :limit, 50)
    offset = Map.get(filters, :offset, 0)
    query |> limit(^limit) |> offset(^offset)
  end
end
