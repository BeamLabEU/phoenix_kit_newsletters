defmodule PhoenixKit.Newsletters.Broadcaster do
  @moduledoc """
  Orchestrates broadcast sending: paginates list members, creates Delivery
  records and Oban jobs in batches.

  ## Rate limiting

  A send profile's `rate_per_hour` / `rate_per_day` / `pause_seconds` are
  enforced here, by spacing each recipient's Oban job with `schedule_in`
  rather than dumping the whole list into the queue at once (see
  `send_interval_seconds/1`).

  The throttle is scoped to one broadcast: two broadcasts sent concurrently
  through the same profile each stay under the limit on their own, but can
  exceed it together. Provider-side quotas (SES in particular) are the real
  backstop — this keeps an ordinary send from tripping them, it is not a
  distributed rate limiter.
  """

  require Logger

  import Ecto.Query

  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.{Broadcast, Content, CRMSource, Delivery, ListMember}
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @batch_size 500

  @hour_seconds 3600
  @day_seconds 86_400

  @doc """
  Starts sending a broadcast. Transitions status to `sending`,
  creates delivery records, and enqueues Oban jobs.
  """
  def send(%Broadcast{status: "draft"} = broadcast) do
    send_if_valid(broadcast)
  end

  def send(%Broadcast{status: "scheduled"} = broadcast) do
    send_if_valid(broadcast)
  end

  def send(%Broadcast{status: status}) do
    {:error, {:invalid_status, status}}
  end

  defp send_if_valid(broadcast) do
    case validate_recipient_source(broadcast) do
      :ok -> do_send(broadcast)
      {:error, _reason} = error -> error
    end
  end

  # An archived CRM list must never receive a send. CRMSource's own
  # sendable_query/1 already excludes an archived list's members (so
  # do_send/1 would just resolve to 0 recipients), but refusing explicitly
  # up front — before status flips to "sending" — keeps the broadcast's
  # own status honest instead of quietly "succeeding" at sending to no
  # one. A missing list (deleted, or CRM not installed) is unchanged from
  # before: proceeds and resolves to 0 recipients, matching how a deleted
  # newsletters_list already behaves.
  defp validate_recipient_source(%Broadcast{
         source_type: "crm_list",
         crm_list_uuid: crm_list_uuid
       }) do
    case CRMSource.get_list(crm_list_uuid) do
      %{status: status} when status != "active" -> {:error, {:crm_list_not_active, status}}
      _ -> :ok
    end
  end

  defp validate_recipient_source(%Broadcast{}), do: :ok

  defp do_send(broadcast) do
    repo = repo()

    # Render markdown to HTML and plain text before sending
    html = Content.render_markdown(broadcast.markdown_body)
    text = Content.strip_html(html)

    {:ok, broadcast} =
      Newsletters.update_broadcast(broadcast, %{
        status: "sending",
        html_body: html,
        text_body: text,
        sent_at: UtilsDate.utc_now()
      })

    # Count total recipients — a CRM-sourced broadcast counts its resolved
    # sendable CRM members; a newsletters-list broadcast counts active
    # ListMembers, same as before.
    total = count_recipients(broadcast)
    {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{total_recipients: total})

    # Resolve the very profile the worker will send with, so the throttle we
    # apply here matches the rate limits of the profile that actually sends.
    interval =
      broadcast
      |> DeliveryWorker.resolve_send_profile()
      |> send_interval_seconds()

    # Process in batches using transaction-wrapped stream
    case repo.transaction(fn -> enqueue_all_recipients(broadcast, repo, interval) end) do
      {:ok, _} ->
        Logger.info(
          "Broadcaster: Enqueued #{total} deliveries for broadcast #{broadcast.uuid}" <>
            throttle_log(interval, total)
        )

        {:ok, broadcast}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Minimum gap between two sends for a profile, in seconds.

  An operator can cap the same send three ways — per hour, per day, and an
  explicit pause — so the tightest one wins: each is a ceiling the send must
  not exceed, and honoring only the loosest would breach the others.

  A profile that sets none of them (or no profile at all) yields `0`, which
  keeps the original "enqueue everything at once" behavior. `0` is treated
  as "unset" rather than "never send", matching how an empty form field
  round-trips — and it keeps this from dividing by zero.
  """
  @spec send_interval_seconds(SendProfile.t() | nil) :: non_neg_integer()
  def send_interval_seconds(nil), do: 0

  def send_interval_seconds(%SendProfile{} = profile) do
    [
      rate_interval(profile.rate_per_hour, @hour_seconds),
      rate_interval(profile.rate_per_day, @day_seconds),
      max(profile.pause_seconds || 0, 0)
    ]
    |> Enum.max()
  end

  defp rate_interval(rate, _window) when is_nil(rate) or rate <= 0, do: 0
  defp rate_interval(rate, window), do: ceil(window / rate)

  defp throttle_log(0, _total), do: " (no rate limit)"

  defp throttle_log(interval, total) do
    span = div(max(total - 1, 0) * interval, 60)
    " (throttled to 1 per #{interval}s — the last one goes out in ~#{span} min)"
  end

  defp count_recipients(%Broadcast{source_type: "crm_list", crm_list_uuid: crm_list_uuid}) do
    crm_list_uuid
    |> CRMSource.sendable_recipients()
    |> length()
  end

  defp count_recipients(%Broadcast{list_uuid: list_uuid}) do
    Newsletters.count_active_members(list_uuid)
  end

  # A crm_list broadcast resolves its recipients from CRMSource (already a
  # fully-materialized, deduplicated list — CRM lists run in the low
  # thousands, not worth streaming), each carrying an email but no
  # user_uuid. A newsletters_list broadcast keeps the original streamed
  # user_uuid path. Both funnel into the same process_batch/5, which only
  # cares that each recipient map has a user_uuid and/or recipient_email.
  defp enqueue_all_recipients(%Broadcast{source_type: "crm_list"} = broadcast, repo, interval) do
    broadcast.crm_list_uuid
    |> CRMSource.sendable_recipients()
    |> Enum.map(fn %{email: email} -> %{user_uuid: nil, recipient_email: email} end)
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn recipients, offset ->
      process_batch(broadcast, recipients, repo, interval, offset)
      offset + length(recipients)
    end)
  end

  defp enqueue_all_recipients(broadcast, repo, interval) do
    broadcast.list_uuid
    |> stream_active_members()
    |> Stream.map(fn user_uuid -> %{user_uuid: user_uuid, recipient_email: nil} end)
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce(0, fn recipients, offset ->
      process_batch(broadcast, recipients, repo, interval, offset)
      offset + length(recipients)
    end)
  end

  defp stream_active_members(list_uuid) do
    ListMember
    |> where([m], m.list_uuid == ^list_uuid and m.status == "active")
    |> select([m], m.user_uuid)
    |> repo().stream()
  end

  defp process_batch(broadcast, recipients, repo, interval, offset) do
    now = UtilsDate.utc_now()

    deliveries =
      Enum.map(recipients, fn recipient ->
        Map.merge(recipient, %{
          uuid: UUIDv7.generate(),
          broadcast_uuid: broadcast.uuid,
          status: "pending",
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, inserted} = repo.insert_all(Delivery, deliveries, returning: [:uuid])

    # `offset` continues the recipient count across batches, so the spacing is
    # continuous over the whole broadcast rather than restarting each chunk —
    # otherwise every batch would dump its first 500 sends at once.
    jobs =
      inserted
      |> Enum.with_index(offset)
      |> Enum.map(fn {%{uuid: delivery_uuid}, index} ->
        DeliveryWorker.new(
          %{delivery_uuid: delivery_uuid, broadcast_uuid: broadcast.uuid},
          schedule_opts(interval, index)
        )
      end)

    Oban.insert_all(jobs)
  end

  # No rate limit: insert with no scheduling at all, byte-for-byte the old
  # behavior. Otherwise space recipient N out by N intervals.
  defp schedule_opts(0, _index), do: []
  defp schedule_opts(interval, index), do: [schedule_in: index * interval]

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
