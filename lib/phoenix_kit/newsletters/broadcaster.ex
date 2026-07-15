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
  alias PhoenixKit.Newsletters.{Broadcast, Content, Delivery, ListMember}
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
    do_send(broadcast)
  end

  def send(%Broadcast{status: "scheduled"} = broadcast) do
    do_send(broadcast)
  end

  def send(%Broadcast{status: status}) do
    {:error, {:invalid_status, status}}
  end

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

    # Count total active members
    total = Newsletters.count_active_members(broadcast.list_uuid)
    {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{total_recipients: total})

    # Resolve the very profile the worker will send with, so the throttle we
    # apply here matches the rate limits of the profile that actually sends.
    interval =
      broadcast
      |> DeliveryWorker.resolve_send_profile()
      |> send_interval_seconds()

    # Process in batches using transaction-wrapped stream
    case repo.transaction(fn -> enqueue_all_members(broadcast, repo, interval) end) do
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

  defp enqueue_all_members(broadcast, repo, interval) do
    broadcast.list_uuid
    |> stream_active_members()
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce(0, fn user_uuids, offset ->
      process_batch(broadcast, user_uuids, repo, interval, offset)
      offset + length(user_uuids)
    end)
  end

  defp stream_active_members(list_uuid) do
    ListMember
    |> where([m], m.list_uuid == ^list_uuid and m.status == "active")
    |> select([m], m.user_uuid)
    |> repo().stream()
  end

  defp process_batch(broadcast, user_uuids, repo, interval, offset) do
    now = UtilsDate.utc_now()

    deliveries =
      Enum.map(user_uuids, fn user_uuid ->
        %{
          uuid: UUIDv7.generate(),
          broadcast_uuid: broadcast.uuid,
          user_uuid: user_uuid,
          status: "pending",
          inserted_at: now,
          updated_at: now
        }
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
