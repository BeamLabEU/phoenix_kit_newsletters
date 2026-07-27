defmodule PhoenixKit.Newsletters.AttachmentCache do
  @moduledoc """
  Process-global cache of resolved broadcast attachments, keyed on file uuid.

  A broadcast enqueues one `PhoenixKit.Newsletters.Workers.DeliveryWorker`
  job per recipient and every one of them attaches the same files, so
  without a cache shared *across* jobs a 10k-recipient broadcast carrying
  three attachments pulls 30k objects out of Storage. Keyed on file uuid
  rather than broadcast uuid on purpose: a file reused by two broadcasts
  inside the TTL is fetched once.

  ## Why a supervised owner

  An ETS table is destroyed when its owner process exits, and Oban runs
  every job in a fresh, short-lived process. A table created lazily inside
  `perform/1` therefore dies with the first job that finishes — the cache
  never actually spans jobs — and a concurrent job that already saw the
  table exist crashes with `ArgumentError` when the owner exits between its
  existence check and its `:ets.lookup/2`. Owning the table here, from a
  process supervised for the lifetime of the application, removes both.

  Reads and writes still go straight to ETS — the table is `:public`, so
  concurrent workers on different keys never contend and nothing queues
  behind this process. The GenServer only owns the table and sweeps it.

  ## Expiry

  Entries live for two minutes: attachments rarely change
  mid-broadcast, but a re-upload replacing the same uuid's content should
  eventually be picked up. Expired entries are dropped lazily on read *and*
  by a periodic sweep — the sweep is what bounds memory, since the
  attachments of a finished broadcast are never read again and would
  otherwise sit in the table (as multi-MB binaries) for the life of the
  node.

  The cache is an optimisation, never a precondition for delivery: every
  operation degrades to a miss if the table isn't there (this library's
  application not started, or a node shutting down).
  """

  use GenServer

  @table :phoenix_kit_newsletters_attachment_cache
  @ttl_ms :timer.minutes(2)
  @sweep_interval_ms :timer.minutes(1)

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached attachment for `file_uuid`, or `:miss`.

  An entry past its TTL is deleted and reported as a miss rather than
  served stale.
  """
  @spec fetch(String.t()) :: {:ok, Swoosh.Attachment.t()} | :miss
  def fetch(file_uuid) do
    case :ets.lookup(@table, file_uuid) do
      [{^file_uuid, attachment, expires_at}] ->
        if now() < expires_at do
          {:ok, attachment}
        else
          :ets.delete(@table, file_uuid)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Caches `attachment` under `file_uuid` and returns it unchanged, so it can
  be used inline on the fetch path.
  """
  @spec put(String.t(), Swoosh.Attachment.t()) :: Swoosh.Attachment.t()
  def put(file_uuid, attachment) do
    :ets.insert(@table, {file_uuid, attachment, now() + @ttl_ms})
    attachment
  rescue
    ArgumentError -> attachment
  end

  @doc "Drops every entry. Intended for tests."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Deletes every entry whose expiry has already passed in one pass, so a
  # broadcast's attachments don't outlive their TTL just because nothing
  # reads them again.
  defp sweep do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
  end

  defp now, do: System.monotonic_time(:millisecond)
end
