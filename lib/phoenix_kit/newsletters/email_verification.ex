defmodule PhoenixKit.Newsletters.EmailVerification do
  # `apply/3` on purpose: the engine is whatever module the host names in its
  # configuration, so this package cannot reference it at compile time. Every
  # call is gated by `Code.ensure_loaded?/1` + `function_exported?/3`.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Optional, soft bridge to the host's address verification engine: the module
  named by

      config :phoenix_kit_newsletters, :email_verification_engine, MyApp.AddressVerification

  Its contract is `PhoenixKit.Newsletters.VerificationEngine`. There is no
  default engine: with nothing configured this bridge behaves as it does for a
  configured module that is not loaded.

  Newsletters has no table of subscribers of its own — an audience is a CRM
  list or a set of roles, resolved at send time — so the engine takes plain
  lists of addresses and this module only forwards them. Every function
  degrades when there is no engine (none configured, the module not loaded, or a
  module without `verify/2`): a read gives a neutral value (`%{}`, `nil`,
  all-unchecked counts, `false`), an action gives `{:error, :unavailable}`. A
  failure inside a read is logged and treated the same way, so a broken engine
  never takes the page down. Starting a batch is told apart: when the engine is
  loaded and raises (or exits), `start_batch/4` answers
  `{:error, {:engine_error, message}}` — the engine is there, it is the batch
  that did not start.
  """

  require Logger

  alias PhoenixKit.Newsletters.VerificationEngine

  @engine_key :email_verification_engine

  @type summary :: VerificationEngine.summary()

  @doc """
  Whether an engine is configured and loaded: the configured module exists and
  exports `verify/2`.
  """
  @spec available?() :: boolean()
  def available? do
    case engine() do
      module when is_atom(module) and not is_nil(module) ->
        Code.ensure_loaded?(module) and function_exported?(module, :verify, 2)

      _ ->
        false
    end
  end

  @doc "Whether the engine is there and switched on (its own `enabled?/0`)."
  @spec enabled?() :: boolean()
  def enabled?, do: call(:enabled?, [], false)

  @doc """
  Whether the host's Oban config declares the queue the engine's batches run in.
  `false` when there is no engine.
  """
  @spec queue_configured?() :: boolean()
  def queue_configured?, do: call(:queue_configured?, [], false)

  @doc "Stored verdicts by address, as the engine returns them; `%{}` without it."
  @spec results_for([String.t()]) :: %{String.t() => VerificationEngine.verdict()}
  def results_for(emails) when is_list(emails), do: call(:results_for, [emails], %{})

  @doc """
  Stored `%{status:, reason:, level:}` by address, without the step logs: for
  filtering and counting a whole audience. An engine without `statuses_for/1` is
  asked for `results_for/1` instead.
  """
  @spec statuses_for([String.t()]) :: %{String.t() => VerificationEngine.status_info()}
  def statuses_for(emails) when is_list(emails) do
    if available?() and function_exported?(engine(), :statuses_for, 1) do
      call(:statuses_for, [emails], %{})
    else
      results_for(emails)
    end
  end

  @doc "Counts of `emails` by stored status; everything `unchecked` without the engine."
  @spec summary([String.t()]) :: summary()
  def summary(emails) when is_list(emails) do
    call(:summary, [emails], unchecked_summary(emails))
  end

  @doc """
  Starts a background batch. `{:error, :unavailable}` without the engine;
  `{:error, {:engine_error, message}}` when the engine is there and raised.
  """
  @spec start_batch([String.t()], String.t(), term(), VerificationEngine.batch_opts()) ::
          {:ok, VerificationEngine.batch()} | {:error, term()}
  def start_batch(emails, source_type, source_ref, opts \\ []) when is_list(emails) do
    call(:start_batch, [emails, source_type, source_ref, opts], {:error, :unavailable}, fn
      message -> {:error, {:engine_error, message}}
    end)
  end

  @doc "The newest batch of one source, or `nil`."
  @spec latest_batch(String.t(), term()) :: VerificationEngine.batch() | nil
  def latest_batch(source_type, source_ref),
    do: call(:latest_batch, [source_type, source_ref], nil)

  @doc "A batch by uuid, or `nil`."
  @spec get_batch(term()) :: VerificationEngine.batch() | nil
  def get_batch(uuid), do: call(:get_batch, [uuid], nil)

  @doc """
  Subscribes the calling process to a batch's progress. The messages are the
  engine's `{:email_verify_batch, %{uuid:, state:, processed:, total:, counts:}}`
  (`t:PhoenixKit.Newsletters.VerificationEngine.progress_message/0`).
  """
  @spec subscribe_batch(String.t()) :: :ok | {:error, term()}
  def subscribe_batch(uuid), do: call(:subscribe_batch, [uuid], {:error, :unavailable})

  @doc "The most distinct addresses one batch can hold, or `nil` without the engine."
  @spec max_batch_size() :: pos_integer() | nil
  def max_batch_size, do: call(:max_batch_size, [], nil)

  @doc """
  The engine's SMTP mode (`"off"`, `"runner"` or `"local"`). `"off"` without an
  engine and with one that has no SMTP stage.
  """
  @spec smtp_mode() :: String.t()
  def smtp_mode, do: call(:smtp_mode, [], "off")

  @doc """
  What the engine knows about the SMTP runner (a map with at least `:state`:
  `:online`, `:offline` or `:never_connected`), or `nil` when it cannot say: no
  engine, an engine without the SMTP stage, or a failed read.
  """
  @spec runner_status() :: map() | nil
  def runner_status, do: call(:runner_status, [], nil)

  @doc """
  The path of the engine's own settings page, or `nil` when the engine has none
  (or has no `settings_path/0`, or answers something that is not an absolute path
  of this site: a link built from the answer must not leave it).
  """
  @spec settings_path() :: String.t() | nil
  def settings_path do
    case call(:settings_path, [], nil) do
      "//" <> _ -> nil
      "/" <> _ = path -> path
      _ -> nil
    end
  end

  @doc """
  Whether addresses are queued for a remote runner that is not online: the mode
  is `"runner"` and the runner has never connected or has stopped answering.
  `false` when the engine cannot say.
  """
  @spec smtp_runner_waiting?() :: boolean()
  def smtp_runner_waiting? do
    smtp_mode() == "runner" and
      match?(%{state: state} when state != :online, runner_status())
  end

  # Resolved at call time: a host sets it in its config, a test stands in for the
  # engine (or for its absence). Unset is `nil`, which is no engine.
  defp engine, do: Application.get_env(:phoenix_kit_newsletters, @engine_key)

  defp unchecked_summary(emails) do
    %{valid: 0, invalid: 0, temp: 0, not_sure: 0, unchecked: length(emails)}
  end

  # `on_failure` turns the message of a raise or exit inside the engine into
  # the answer; by default the failure reads like the engine's absence.
  defp call(function, args, default, on_failure \\ nil) do
    if available?() and function_exported?(engine(), function, length(args)) do
      apply(engine(), function, args)
    else
      default
    end
  rescue
    e ->
      message = e |> Exception.message() |> mask_addresses()
      Logger.warning("[Newsletters] email verification #{function} failed: #{message}")
      failure(on_failure, message, default)
  catch
    :exit, reason ->
      message = reason |> inspect() |> mask_addresses()
      Logger.warning("[Newsletters] email verification #{function} exited: #{message}")
      failure(on_failure, "exited: " <> message, default)
  end

  # An engine message may quote the addresses of a failed insert; a log line and
  # an error tuple that travels on must not carry them.
  # An address starts only at a token boundary (the lookbehind), and '@' is not
  # a token character, so a long run of text cannot make the scan quadratic.
  @address ~r/(?<![^\s<>()\[\]"',;=])[^\s<>()\[\]"',;=@]+@[^\s<>()\[\]"',;=@]+/

  defp mask_addresses(message), do: Regex.replace(@address, message, &mask/1)

  defp mask(address) do
    case String.split(address, "@") do
      [local, domain] when local != "" -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp failure(nil, _message, default), do: default
  defp failure(on_failure, message, _default), do: on_failure.(message)
end
