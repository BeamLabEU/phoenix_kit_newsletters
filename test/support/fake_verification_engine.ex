defmodule PhoenixKitNewsletters.Test.FakeVerificationEngine do
  @moduledoc """
  A scripted `PhoenixKit.Newsletters.VerificationEngine`, for tests that are
  about this package's side of the bridge, not about an engine. Install it with
  `Application.put_env(:phoenix_kit_newsletters, :email_verification_engine, __MODULE__)`.

  Answers are scripted in the *calling process's* dictionary (`put/2`), and the
  calls that change something are sent to that process as messages
  (`{:start_batch, emails, source_type, source_ref, opts}`,
  `{:subscribe_batch, uuid}`), so a test asserts on what the page asked for.
  """

  @behaviour PhoenixKit.Newsletters.VerificationEngine

  @statuses ~w(valid invalid temp not_sure)

  @doc "Scripts an answer: `:enabled`, `:queue_configured`, `:results`, `:latest_batch`, `:batch`, `:start_batch`, `:smtp_mode`, `:runner_status`, `:settings_path`, `:raise`."
  def put(key, value), do: Process.put({__MODULE__, key}, value)

  defp get(key, default), do: Process.get({__MODULE__, key}, default)

  defp maybe_raise do
    case get(:raise, nil) do
      nil -> :ok
      message -> raise message
    end
  end

  @impl true
  def verify(_email, _opts), do: raise("not used")

  @impl true
  def enabled?, do: get(:enabled, true)

  @impl true
  def queue_configured?, do: get(:queue_configured, true)

  @impl true
  def results_for(emails) do
    send(self(), {:results_for, emails})
    maybe_raise()
    Map.take(get(:results, %{}), emails)
  end

  @impl true
  def statuses_for(emails) do
    send(self(), {:statuses_for, emails})
    maybe_raise()

    get(:results, %{})
    |> Map.take(emails)
    |> Map.new(fn {email, result} -> {email, Map.take(result, [:status, :reason, :level])} end)
  end

  @impl true
  def summary(emails) do
    send(self(), {:summary, emails})
    results = get(:results, %{})
    counts = Enum.frequencies_by(emails, &status(results[&1]))

    for status <- [:valid, :invalid, :temp, :not_sure, :unchecked], into: %{} do
      {status, Map.get(counts, status, 0)}
    end
  end

  @impl true
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

  @impl true
  def latest_batch(source_type, source_ref) do
    send(self(), {:latest_batch, source_type, source_ref})
    get(:latest_batch, nil)
  end

  @impl true
  def get_batch(uuid) do
    send(self(), {:get_batch, uuid})
    get(:batch, nil)
  end

  @impl true
  def subscribe_batch(uuid) do
    send(self(), {:subscribe_batch, uuid})
    :ok
  end

  @impl true
  def max_batch_size, do: 100

  @impl true
  def smtp_mode, do: get(:smtp_mode, "off")

  @impl true
  def runner_status, do: get(:runner_status, %{state: :never_connected})

  @impl true
  def settings_path, do: get(:settings_path, nil)

  defp status(nil), do: :unchecked
  defp status(%{status: status}) when status in @statuses, do: String.to_existing_atom(status)
  defp status(_), do: :unchecked
end
