defmodule PhoenixKitNewsletters.Test.FakeVerificationEngine do
  @moduledoc """
  Stands in for `PhoenixKit.Modules.Emails.Verification` where a test is about
  this package's side of the bridge, not the engine: it works with or without
  `phoenix_kit_emails` in the build. Install it with
  `Application.put_env(:phoenix_kit_newsletters, :email_verification_engine, __MODULE__)`.

  Answers are scripted in the *calling process's* dictionary (`put/2`), and the
  calls that change something are sent to that process as messages
  (`{:start_batch, emails, source_type, source_ref, opts}`,
  `{:subscribe_batch, uuid}`), so a test asserts on what the page asked for.
  """

  @statuses ~w(valid invalid temp not_sure)

  @doc "Scripts an answer: `:enabled`, `:queue_configured`, `:results`, `:latest_batch`, `:batch`, `:start_batch`, `:raise`."
  def put(key, value), do: Process.put({__MODULE__, key}, value)

  defp get(key, default), do: Process.get({__MODULE__, key}, default)

  defp maybe_raise do
    case get(:raise, nil) do
      nil -> :ok
      message -> raise message
    end
  end

  def verify(_email, _opts), do: raise("not used")

  def enabled?, do: get(:enabled, true)
  def queue_configured?, do: get(:queue_configured, true)

  def results_for(emails) do
    send(self(), {:results_for, emails})
    maybe_raise()
    Map.take(get(:results, %{}), emails)
  end

  def summary(emails) do
    results = get(:results, %{})
    counts = Enum.frequencies_by(emails, &status(results[&1]))

    for status <- [:valid, :invalid, :temp, :not_sure, :unchecked], into: %{} do
      {status, Map.get(counts, status, 0)}
    end
  end

  def start_batch([], _source_type, _source_ref, _opts), do: {:error, :no_emails}

  def start_batch(emails, source_type, source_ref, opts) do
    send(self(), {:start_batch, emails, source_type, source_ref, opts})

    get(
      :start_batch,
      {:ok,
       %{
         uuid: Ecto.UUID.generate(),
         state: "queued",
         processed: 0,
         total: length(emails),
         counts: %{},
         finished_at: nil
       }}
    )
  end

  def latest_batch(source_type, source_ref) do
    send(self(), {:latest_batch, source_type, source_ref})
    get(:latest_batch, nil)
  end

  def get_batch(_uuid), do: get(:batch, nil)

  def subscribe_batch(uuid) do
    send(self(), {:subscribe_batch, uuid})
    :ok
  end

  def max_batch_size, do: 100

  defp status(nil), do: :unchecked
  defp status(%{status: status}) when status in @statuses, do: String.to_existing_atom(status)
  defp status(_), do: :unchecked
end
