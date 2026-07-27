defmodule PhoenixKit.Newsletters.AttachmentCacheTest do
  @moduledoc """
  Cache mechanics only — no DB and no Storage round trips (those are
  exercised through `DeliveryWorker.build_attachment/2` in
  `delivery_worker_test.exs`). What matters here is the property the whole
  cross-job cache rests on: an entry written by one process is still
  readable by another *after the writer has exited*.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Newsletters.AttachmentCache

  setup do
    AttachmentCache.clear()
    :ok
  end

  defp attachment(name) do
    Swoosh.Attachment.new({:data, "bytes of #{name}"}, filename: name, type: :attachment)
  end

  test "an entry written by a short-lived process outlives that process" do
    # The exact production shape: Oban runs every delivery job in a fresh
    # process that exits as soon as the job returns. When the ETS table was
    # created lazily inside the worker, it was owned by that job's process
    # and died with it — the "cross-job" cache never survived a single job.
    uuid = Ecto.UUID.generate()
    parent = self()

    writer =
      spawn(fn ->
        AttachmentCache.put(uuid, attachment("flyer.txt"))
        send(parent, :written)
      end)

    ref = Process.monitor(writer)
    assert_receive :written
    assert_receive {:DOWN, ^ref, :process, ^writer, _reason}

    assert {:ok, %Swoosh.Attachment{filename: "flyer.txt"}} = AttachmentCache.fetch(uuid)
  end

  test "concurrent readers in separate processes all see the same entry" do
    uuid = Ecto.UUID.generate()
    AttachmentCache.put(uuid, attachment("shared.txt"))

    results =
      1..10
      |> Task.async_stream(fn _ -> AttachmentCache.fetch(uuid) end, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Swoosh.Attachment{filename: "shared.txt"}}, &1))
  end

  test "an unknown uuid is a miss" do
    assert AttachmentCache.fetch(Ecto.UUID.generate()) == :miss
  end

  test "an entry past its expiry is a miss, and is dropped rather than served stale" do
    uuid = Ecto.UUID.generate()
    expired_at = System.monotonic_time(:millisecond) - 1

    :ets.insert(
      :phoenix_kit_newsletters_attachment_cache,
      {uuid, attachment("old.txt"), expired_at}
    )

    assert AttachmentCache.fetch(uuid) == :miss
    assert :ets.lookup(:phoenix_kit_newsletters_attachment_cache, uuid) == []
  end

  test "the periodic sweep drops expired entries nothing ever reads again" do
    # Lazy eviction alone can't bound memory: once a broadcast finishes,
    # its attachments are never looked up again, so without the sweep their
    # (multi-MB) binaries would sit in the table for the life of the node.
    expired = Ecto.UUID.generate()
    live = Ecto.UUID.generate()
    now = System.monotonic_time(:millisecond)

    :ets.insert(
      :phoenix_kit_newsletters_attachment_cache,
      {expired, attachment("old.txt"), now - 1}
    )

    AttachmentCache.put(live, attachment("current.txt"))

    send(AttachmentCache, :sweep)
    # Round-trip a call through the process so the :sweep above is known to
    # have been handled before asserting.
    _ = :sys.get_state(AttachmentCache)

    assert :ets.lookup(:phoenix_kit_newsletters_attachment_cache, expired) == []
    assert {:ok, %Swoosh.Attachment{filename: "current.txt"}} = AttachmentCache.fetch(live)
  end

  test "put/2 returns the attachment unchanged so it can be used inline" do
    attachment = attachment("inline.txt")
    assert AttachmentCache.put(Ecto.UUID.generate(), attachment) == attachment
  end
end
