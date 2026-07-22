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
  alias PhoenixKit.Newsletters.{Broadcast, Content, CRMSource, Delivery}
  alias PhoenixKit.Newsletters.UserGroupSource
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
  # before: proceeds and resolves to 0 recipients rather than erroring.
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

    # Recipients are resolved once, upfront, and reused for both the
    # total_recipients count and the actual enqueue below (rather than
    # two separate identical queries).
    recipients = resolve_recipients(broadcast)

    total = length(recipients)
    {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{total_recipients: total})

    # Resolve the very profile the worker will send with, so the throttle we
    # apply here matches the rate limits of the profile that actually sends.
    interval =
      broadcast
      |> DeliveryWorker.resolve_send_profile()
      |> send_interval_seconds()

    # Process in batches using transaction-wrapped stream
    case repo.transaction(fn -> enqueue_all_recipients(broadcast, recipients, repo, interval) end) do
      {:ok, %{inserted: inserted, duplicate: duplicate}} ->
        # total_recipients was set from the pre-send estimate above; a
        # re-enqueue of a broadcast that already has deliveries (the
        # V155 unique indexes turning some inserts into no-ops) means
        # `inserted` here is only THIS round's delta, not the audience
        # size — using it directly would zero out total_recipients on a
        # duplicate-only resend even though the broadcast's original N
        # deliveries still exist and sent_count keeps climbing toward
        # them. The actual row count for the broadcast is the correct
        # figure regardless of how many resend rounds contributed to it.
        actual_total = count_deliveries(repo, broadcast.uuid)

        {:ok, broadcast} =
          if actual_total != total do
            Newsletters.update_broadcast(broadcast, %{total_recipients: actual_total})
          else
            {:ok, broadcast}
          end

        Logger.info(
          "Broadcaster: Enqueued #{inserted} deliveries for broadcast #{broadcast.uuid}" <>
            duplicate_log(duplicate) <> throttle_log(interval, inserted)
        )

        {:ok, broadcast}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_deliveries(repo, broadcast_uuid) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> repo.aggregate(:count)
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

  defp duplicate_log(0), do: ""

  defp duplicate_log(count) do
    " (#{count} duplicate recipient(s) skipped — already delivered for this broadcast)"
  end

  defp resolve_recipients(%Broadcast{source_type: "crm_list", crm_list_uuid: crm_list_uuid}) do
    CRMSource.sendable_recipients(crm_list_uuid)
  end

  defp resolve_recipients(%Broadcast{source_type: "user_group"} = broadcast) do
    broadcast |> Broadcast.role_uuids() |> UserGroupSource.sendable_recipients()
  end

  # Totality guard: V156 re-pointed every 'newsletters_list' row and the
  # changeset only admits crm_list/user_group, so this clause should be
  # unreachable — but an unexpected stray row should degrade to "sent to
  # nobody" with a log line, not take the send path down with a
  # FunctionClauseError.
  defp resolve_recipients(%Broadcast{} = broadcast) do
    Logger.warning(
      "Broadcaster: broadcast #{broadcast.uuid} has unknown source_type " <>
        "#{inspect(broadcast.source_type)} — resolving to zero recipients"
    )

    []
  end

  # A crm_list or user_group broadcast's recipients are already resolved
  # (by resolve_recipients/1, called once in do_send/1) — a
  # fully-materialized, deduplicated list (both run in the low thousands,
  # not worth streaming), each carrying an email and a contact_uuid (no
  # user_uuid, for crm_list) or a user_uuid (for user_group). Both funnel
  # into the same process_batch/5, which only cares that each recipient
  # map has a user_uuid and/or recipient_email.
  defp enqueue_all_recipients(
         %Broadcast{source_type: "crm_list"} = broadcast,
         recipients,
         repo,
         interval
       ) do
    recipients
    |> Enum.map(fn %{contact_uuid: contact_uuid, email: email} ->
      %{user_uuid: nil, crm_contact_uuid: contact_uuid, recipient_email: email}
    end)
    |> Enum.chunk_every(@batch_size)
    |> reduce_batches(broadcast, repo, interval)
  end

  defp enqueue_all_recipients(
         %Broadcast{source_type: "user_group"} = broadcast,
         recipients,
         repo,
         interval
       ) do
    recipients
    |> Enum.map(fn %{user_uuid: user_uuid} ->
      %{user_uuid: user_uuid, crm_contact_uuid: nil, recipient_email: nil}
    end)
    |> Enum.chunk_every(@batch_size)
    |> reduce_batches(broadcast, repo, interval)
  end

  # Shared batch-accumulation loop for both recipient sources: `offset`
  # continues across batches based on how many rows each batch actually
  # inserted (not how many were requested), so throttle spacing isn't
  # wasted on duplicates process_batch/5's ON CONFLICT DO NOTHING skips;
  # `inserted`/`duplicate` accumulate into the totals do_send/1 reports.
  defp reduce_batches(batches, broadcast, repo, interval) do
    batches
    |> Enum.reduce(%{offset: 0, inserted: 0, duplicate: 0}, fn batch, acc ->
      {inserted_count, duplicate_count} =
        process_batch(broadcast, batch, repo, interval, acc.offset)

      %{
        offset: acc.offset + inserted_count,
        inserted: acc.inserted + inserted_count,
        duplicate: acc.duplicate + duplicate_count
      }
    end)
    |> Map.take([:inserted, :duplicate])
  end

  # Returns `{inserted_count, duplicate_count}`. `on_conflict: :nothing`
  # with no `conflict_target` — Postgres's `ON CONFLICT DO NOTHING` with no
  # arbiter applies to a violation of ANY of the table's unique
  # constraints, which is what's needed here: a duplicate can trip any one
  # of the V155 partial unique indexes (per-user, per-contact, or
  # per-email), depending on which recipient source produced the row.
  # `RETURNING` on a conflicting row returns nothing for it (Postgres
  # semantics), so `inserted` already excludes duplicates — the count is
  # `length(inserted)`, and the gap against the requested batch size is
  # what got deduplicated.
  defp process_batch(broadcast, recipients, repo, interval, offset) do
    now = UtilsDate.utc_now()

    {deliveries, skipped} =
      recipients
      |> Enum.map(fn recipient ->
        Map.merge(recipient, %{
          uuid: UUIDv7.generate(),
          broadcast_uuid: broadcast.uuid,
          status: "pending",
          inserted_at: now,
          updated_at: now
        })
      end)
      |> Enum.split_with(&valid_recipient?/1)

    if skipped != [] do
      Logger.warning(
        "Broadcaster: skipped #{length(skipped)} recipient(s) with neither user_uuid nor " <>
          "recipient_email for broadcast #{broadcast.uuid} (insert_all bypasses Delivery's " <>
          "changeset validation, so this must be checked explicitly)"
      )
    end

    {_count, inserted} =
      repo.insert_all(Delivery, deliveries, returning: [:uuid], on_conflict: :nothing)

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

    {length(inserted), length(deliveries) - length(inserted)}
  end

  # No rate limit: insert with no scheduling at all, byte-for-byte the old
  # behavior. Otherwise space recipient N out by N intervals.
  defp schedule_opts(0, _index), do: []
  defp schedule_opts(interval, index), do: [schedule_in: index * interval]

  @doc false
  # Mirrors Delivery.changeset/2's "at least one" validation, which
  # insert_all never runs. Neither current recipient source can actually
  # produce a both-nil row today (CRMSource.sendable_recipients/1 filters
  # `not is_nil(m.email)`; UserGroupSource.sendable_recipients/1 selects a
  # NOT NULL user_uuid) — this is a defensive backstop against a future
  # source, or corrupt data, silently inserting an unaddressable delivery.
  # Not `defp` so it can be unit-tested directly — same rationale as
  # `resolve_send_profile/1`/`build_profile_email/5` in DeliveryWorker.
  def valid_recipient?(%{user_uuid: user_uuid, recipient_email: recipient_email}) do
    not is_nil(user_uuid) or not is_nil(recipient_email)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
