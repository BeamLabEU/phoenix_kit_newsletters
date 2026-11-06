defmodule PhoenixKit.Newsletters do
  @moduledoc """
  Newsletters module — email broadcasts and subscription management.

  Provides broadcast creation with a Markdown editor, audiences from CRM lists
  and core roles, per-recipient delivery tracking via Oban workers, and the
  unsubscribe flow.

  Broadcasts are sent inside an operator-authored layout
  (`PhoenixKit.Newsletters.Layouts`, this package's own table) or, without
  one, inside core's standard email layout for the `"newsletters"` group.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Newsletters.PermissionBackfill
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
      label: gettext_noop("Newsletters"),
      icon: "📨",
      description: gettext_noop("Email broadcasts and subscription management"),
      gettext_backend: PhoenixKit.Newsletters.Gettext,
      # The base key used to let its holder send a broadcast to any audience
      # and read every recipient's address. Those rights are split out here;
      # Admin gets them from core's boot-time auto-grant, Owner through "*",
      # and `migrate_legacy/0` carries every other role that already held
      # `newsletters`, so nobody loses access.
      sub_permissions: [
        %{
          key: "send",
          label: gettext_noop("Send broadcasts"),
          description: gettext_noop("Send a broadcast now, schedule it, or retry a failed send")
        },
        %{
          key: "audiences",
          label: gettext_noop("See recipients"),
          description:
            gettext_noop(
              "See the recipient addresses of a broadcast and use the address verification page"
            )
        }
      ]
    }
  end

  # One flag per sub-key, so a later split gets its own pass.
  @sub_key_backfills [
    {"newsletters.send", "newsletters_send_backfilled"},
    {"newsletters.audiences", "newsletters_audiences_backfilled"}
  ]

  @doc """
  One-time data repairs, run by core at every boot.

  Grants each sub-permission split out of the base `newsletters` key
  (`newsletters.send`, `newsletters.audiences`) once to every role that
  already holds `newsletters`, so the split takes nothing away. Each pass has
  its own flag and is retried on the next boot when it did not finish; see
  `PhoenixKit.Newsletters.PermissionBackfill`.
  """
  @impl PhoenixKit.Module
  def migrate_legacy do
    results =
      Enum.map(@sub_key_backfills, fn {key, flag} ->
        PermissionBackfill.run(module_key(), key, flag)
      end)

    Enum.find(results, :ok, &(&1 != :ok))
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
      ),
      Tab.new!(
        id: :admin_newsletters_layouts,
        label: "Layouts",
        icon: "hero-rectangle-group",
        path: "newsletters/layouts",
        priority: 522,
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        match: :prefix,
        live_view: {Web.LayoutsIndex, :index},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_verification,
        label: "Address verification",
        icon: "hero-shield-check",
        path: "newsletters/verification",
        priority: 523,
        level: :admin,
        permission: "newsletters.audiences",
        parent: :admin_newsletters,
        match: :prefix,
        live_view: {Web.Verification, :index},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_layout_new,
        label: "New layout",
        path: "newsletters/layouts/new",
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        visible: false,
        live_view: {Web.LayoutEditor, :new},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      ),
      Tab.new!(
        id: :admin_newsletters_layout_edit,
        label: "Edit layout",
        path: "newsletters/layouts/:id/edit",
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        visible: false,
        live_view: {Web.LayoutEditor, :edit},
        gettext_backend: PhoenixKit.Newsletters.Gettext
      )
    ]
  end

  # Core's admin email preview (`/admin/settings/email-sending/preview`)
  # lists this entry so a host can see its `_layout-newsletters` /
  # `_header-newsletters` / `_footer-newsletters` files — the chrome a
  # broadcast WITHOUT a layout of its own is sent in — with a sample body.
  # The name is only a catalogue key: a send never resolves a template by it
  # (`PhoenixKit.Newsletters.Render` wraps the broadcast's own HTML), and
  # operator layouts have their own preview in the layout editor.
  @impl PhoenixKit.Module
  def email_templates do
    alias PhoenixKit.Newsletters.Render

    [
      %{
        name: "newsletters_broadcast",
        label: gettext("Newsletter broadcast"),
        description:
          gettext("A broadcast sent without a layout of its own, in the standard layout"),
        defaults: &Render.preview_defaults/0,
        variables: &Render.preview_variables/0,
        layout: Render.group()
      }
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

  @doc """
  The queue `DeliveryWorker` runs in, so `mix phoenix_kit.install` and `update`
  write it and `mix phoenix_kit.doctor` reports it missing. A queue nobody runs
  sends nothing and raises nothing. A limit a host has set is left alone.
  """
  @impl PhoenixKit.Module
  def oban_queues, do: [newsletters_delivery: [limit: 10, kind: :batch]]

  @doc "The public pages live under `/newsletters`, whatever a group is called."
  @impl PhoenixKit.Module
  def reserved_route_prefixes, do: ["newsletters"]

  # Decentralized-migrations protocol (see PhoenixKitNewsletters.Migrations'
  # moduledoc): this module owns the future shape of its two tables even
  # though core's chain still creates them on every install.
  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitNewsletters.Migrations

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`; see `PhoenixKit.Newsletters.ExpectedSchema`.
  """
  @impl PhoenixKit.Module
  def expected_schema, do: PhoenixKit.Newsletters.ExpectedSchema

  @doc """
  The stored files this module's tables point at, for core's orphan check: a
  broadcast's `attachments`, which are read again at send time. Without this a
  file attached to a broadcast counts as an orphan and can be deleted.

  Expanded and matched by equality, as core does for its own JSONB lists: `@>`
  per file cannot be hashed. The table's CHECK guarantees an array to expand.
  """
  @impl PhoenixKit.Module
  def file_references do
    [
      {"phoenix_kit_newsletters_broadcasts",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_newsletters_broadcasts nb CROSS JOIN LATERAL jsonb_array_elements_text(nb.attachments) AS na(file_uuid) WHERE na.file_uuid = ?::text)",
           f.uuid
         )
       )}
    ]
  end

  alias PhoenixKit.Newsletters.{
    Broadcast,
    Broadcaster,
    Content,
    Delivery
  }

  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # A scheduled broadcast has not started and a sending one can still stop;
  # every other status is either not under way or already over.
  @cancellable_statuses ["scheduled", "sending"]

  @broadcast_counters [:sent_count, :delivered_count, :opened_count, :bounced_count]

  # ============================================================================
  # Broadcasts
  # ============================================================================

  def list_broadcasts(filters \\ %{}) do
    Broadcast
    |> maybe_filter_broadcast_status(filters)
    |> order_by([b], desc: b.inserted_at, desc: b.uuid)
    |> apply_pagination(filters)
    |> repo().all()
  end

  @doc "How many broadcasts `list_broadcasts/1` pages through for `filters`."
  def count_broadcasts(filters \\ %{}) do
    Broadcast
    |> maybe_filter_broadcast_status(filters)
    |> repo().aggregate(:count)
  end

  def get_broadcast!(uuid), do: repo().get!(Broadcast, uuid)

  @doc """
  Returns a broadcast with its layout (`broadcast.template`, a
  `PhoenixKit.Newsletters.Layout` or `nil`) loaded.
  """
  def get_broadcast_with_template!(uuid) do
    uuid |> get_broadcast!() |> repo().preload(:template)
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

  @doc """
  Writes `attrs` to a broadcast only while the database still has it as a draft.

  The struct is only as fresh as the page that holds it, so the row is locked
  and judged as it is now: an open tab must not rewrite, or bring back, a
  broadcast that has been sent or cancelled since.
  """
  @spec update_draft(Broadcast.t(), map()) ::
          {:ok, Broadcast.t()}
          | {:error, Ecto.Changeset.t() | {:invalid_status, String.t()} | :not_found}
  def update_draft(%Broadcast{uuid: uuid}, attrs) do
    repo().transaction(fn ->
      case lock_broadcast(uuid) do
        %Broadcast{status: "draft"} = draft -> update_or_rollback(draft, attrs)
        %Broadcast{status: status} -> repo().rollback({:invalid_status, status})
        nil -> repo().rollback(:not_found)
      end
    end)
  end

  defp update_or_rollback(broadcast, attrs) do
    case update_broadcast(broadcast, attrs) do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc false
  # For a caller inside a transaction that decides on the row's real status:
  # whoever holds this lock sees any concurrent status change, or blocks it.
  def lock_broadcast(uuid) do
    Broadcast
    |> where([b], b.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  @doc """
  Stops a broadcast that is scheduled or sending, in one conditional statement,
  so a late click cannot turn a finished broadcast into a cancelled one.

  Only the broadcast row is written: queued jobs stop themselves at their
  status guard, and mail already handed to a provider cannot be retracted.
  """
  @spec cancel_broadcast(Broadcast.t()) ::
          {:ok, Broadcast.t()} | {:error, {:invalid_status, String.t()} | :not_found}
  def cancel_broadcast(%Broadcast{uuid: uuid}) do
    {_count, cancelled} =
      Broadcast
      |> where([b], b.uuid == ^uuid and b.status in ^@cancellable_statuses)
      |> select([b], b)
      |> repo().update_all(set: [status: "cancelled", updated_at: UtilsDate.utc_now()])

    case cancelled do
      [broadcast] -> {:ok, broadcast}
      [] -> cancel_refusal(uuid)
    end
  end

  defp cancel_refusal(uuid) do
    case repo().get(Broadcast, uuid) do
      %Broadcast{status: status} -> {:error, {:invalid_status, status}}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Takes a scheduled broadcast back to a draft, so it can be edited, in one
  conditional statement: a send the tick has already started stays started. It
  keeps its `scheduled_at`, which the editor offers again.
  """
  @spec unschedule_broadcast(Broadcast.t()) ::
          {:ok, Broadcast.t()} | {:error, {:invalid_status, String.t()} | :not_found}
  def unschedule_broadcast(%Broadcast{uuid: uuid}) do
    {_count, drafts} =
      Broadcast
      |> where([b], b.uuid == ^uuid and b.status == "scheduled")
      |> select([b], b)
      |> repo().update_all(set: [status: "draft", updated_at: UtilsDate.utc_now()])

    case drafts do
      [broadcast] -> {:ok, broadcast}
      [] -> cancel_refusal(uuid)
    end
  end

  @doc "Whether a broadcast in `status` can be cancelled."
  @spec cancellable?(String.t()) :: boolean()
  def cancellable?(status), do: status in @cancellable_statuses

  @doc """
  Adds one to a broadcast's counter, for a provider event.

  `phoenix_kit_emails` calls this after `update_delivery_status/3`, so the
  list's delivered and opened columns follow the provider. A broadcast that no
  longer exists is not an error.
  """
  @spec increment_broadcast_counter(String.t(), atom()) :: :ok
  def increment_broadcast_counter(broadcast_uuid, field) when field in @broadcast_counters do
    Broadcast
    |> where([b], b.uuid == ^broadcast_uuid)
    |> repo().update_all(inc: [{field, 1}])

    :ok
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
    # The uuid breaks ties, and there are many: a batch of 500 shares one
    # timestamp, and without a defined order a page can repeat or skip a row.
    |> order_by([d], desc: d.inserted_at, desc: d.uuid)
    |> apply_pagination(filters)
    |> repo().all()
  end

  @doc "How many deliveries `list_deliveries/2` pages through for `filters`."
  def count_deliveries(broadcast_uuid, filters \\ %{}) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> maybe_filter_delivery_status(filters)
    |> repo().aggregate(:count)
  end

  @doc "How many of a broadcast's deliveries `Broadcaster.resend_failed/1` would send again."
  def count_resendable_deliveries(broadcast_uuid) do
    broadcast_uuid |> Delivery.resendable_query() |> repo().aggregate(:count)
  end

  def get_delivery_stats(broadcast_uuid) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> group_by([d], d.status)
    |> select([d], {d.status, count(d.uuid)})
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Writes a delivery's status and `attrs`. An event a provider reports out of order
  still records its timestamp, but cannot walk the status back.
  """
  def update_delivery_status(%Delivery{} = delivery, status, attrs \\ %{}) do
    status = Delivery.next_status(delivery.status, status)

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

    now = UtilsDate.utc_now()

    broadcasts =
      Broadcast
      |> where([b], b.status == "scheduled" and b.scheduled_at <= ^now)
      |> order_by([b], asc: b.scheduled_at)
      |> repo().all()

    count =
      Enum.reduce(broadcasts, 0, fn broadcast, acc ->
        case send_scheduled(broadcast) do
          {:ok, _} -> acc + 1
          {:error, reason} -> handle_scheduled_send_failure(broadcast, reason, acc)
        end
      end)

    {:ok, count}
  end

  # A send that raises rolls back and leaves the broadcast "scheduled", so it
  # comes round again next tick. Unguarded, it would also stop every broadcast
  # due after it, on every tick.
  defp send_scheduled(broadcast) do
    Broadcaster.send(broadcast)
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
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
  #
  # Orphaned deliveries go first, so a broadcast they were holding up finishes
  # in this same pass.
  def repair_stuck_sending_broadcasts do
    fail_orphaned_deliveries()

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

  # A delivery stays "pending" for good when the job that owned it is gone: the
  # node was killed on its last attempt, or someone cancelled the job by hand.
  # Nothing would ever write it, so the broadcast could never finish. Judged per
  # broadcast, and only once none of its jobs can still run, because that is one
  # short-circuiting check where per-delivery would be one per recipient. A job
  # lost early is therefore picked up when the rest of the queue has drained.
  #
  # Not counted as a bounce: no provider refused anything. Written delivery
  # first, the order the worker writes in. Without Oban on this node there is no
  # way to tell, so nothing is touched.
  defp fail_orphaned_deliveries do
    if Oban.whereis(Oban) do
      Broadcast
      |> where([b], b.status == "sending")
      |> where([b], b.uuid in subquery(Delivery.non_terminal_broadcast_uuids_query()))
      |> select([b], b.uuid)
      |> repo().all()
      |> Enum.reject(&DeliveryWorker.jobs_remaining?/1)
      |> Enum.each(&fail_pending_deliveries/1)
    end
  end

  defp fail_pending_deliveries(broadcast_uuid) do
    {count, _} =
      Delivery
      |> where([d], d.broadcast_uuid == ^broadcast_uuid and d.status == "pending")
      |> repo().update_all(
        set: [
          status: "failed",
          error: Delivery.no_result_error(),
          updated_at: UtilsDate.utc_now()
        ]
      )

    Logger.warning(
      "Newsletters: #{count} delivery(ies) of broadcast #{broadcast_uuid} had no job left; " <>
        "marked failed"
    )
  end

  # Non-retryable by the tick: none of these clears on its own, so leaving status
  # "scheduled" here would make every future tick re-fetch this broadcast and log
  # the same failure forever. Terminal "failed" removes it from
  # process_scheduled_broadcasts/0's `status == "scheduled"` query, and the details
  # page shows why and offers a retry. Conditional, so an operator's cancel that
  # landed since this tick read the row stands.
  defp handle_scheduled_send_failure(broadcast, reason, acc) do
    if permanent_send_failure?(reason) do
      Logger.error("Scheduled broadcast #{broadcast.uuid} failed permanently: #{inspect(reason)}")

      Broadcast
      |> where([b], b.uuid == ^broadcast.uuid and b.status == "scheduled")
      |> repo().update_all(set: [status: "failed", updated_at: UtilsDate.utc_now()])
    else
      Logger.warning("Failed to send scheduled broadcast #{broadcast.uuid}: #{inspect(reason)}")
    end

    acc
  end

  defp permanent_send_failure?({:crm_list_not_active, _status}), do: true
  defp permanent_send_failure?(reason), do: reason in [:no_recipients, :blank_body]

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp repo, do: PhoenixKit.RepoHelper.repo()

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
