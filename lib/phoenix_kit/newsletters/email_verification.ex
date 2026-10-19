defmodule PhoenixKit.Newsletters.EmailVerification do
  # `apply/3` on purpose: `phoenix_kit_emails` is not a dependency of this
  # package, so a direct call to `PhoenixKit.Modules.Emails.Verification`
  # would be a compile-time "undefined module" warning on every host without
  # it (and the engine ships only in newer Emails releases). Every call is
  # gated by `Code.ensure_loaded?/1` + `function_exported?/3`.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Optional, soft bridge to the address-verification engine of the Emails
  module (`PhoenixKit.Modules.Emails.Verification`).

  Newsletters has no table of subscribers of its own — an audience is a CRM
  list or a set of roles, resolved at send time — so the engine takes plain
  lists of addresses and this module only forwards them. Every function
  degrades when Emails (or a release that has the engine) is not installed:
  a read gives a neutral value (`%{}`, `nil`, all-unchecked counts, `false`),
  an action gives `{:error, :unavailable}`. A failure inside a read is logged
  and treated the same way, so a broken engine never takes the page down.
  Starting a batch is told apart: when the engine is loaded and raises (or
  exits), `start_batch/4` answers `{:error, {:engine_error, message}}` — the
  module is there, it is the batch that did not start.
  """

  require Logger

  @default_engine PhoenixKit.Modules.Emails.Verification

  @type summary :: %{
          valid: non_neg_integer(),
          invalid: non_neg_integer(),
          temp: non_neg_integer(),
          not_sure: non_neg_integer(),
          unchecked: non_neg_integer()
        }

  @doc "Whether the engine is loaded in this host."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(engine()) and function_exported?(engine(), :verify, 2)
  end

  @doc "Whether the engine is there and switched on (`email_verify_enabled`)."
  @spec enabled?() :: boolean()
  def enabled?, do: call(:enabled?, [], false)

  @doc """
  Whether the host's Oban config declares the `:email_verification` queue.
  `false` when the engine is absent.
  """
  @spec queue_configured?() :: boolean()
  def queue_configured?, do: call(:queue_configured?, [], false)

  @doc "Stored verdicts by address, as the engine returns them; `%{}` without it."
  @spec results_for([String.t()]) :: %{String.t() => map()}
  def results_for(emails) when is_list(emails), do: call(:results_for, [emails], %{})

  @doc """
  Stored `%{status:, reason:, level:}` by address, without the step logs: for
  filtering and counting a whole audience. An engine release that predates
  `statuses_for/1` is asked for `results_for/1` instead.
  """
  @spec statuses_for([String.t()]) :: %{String.t() => map()}
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
  @spec start_batch([String.t()], String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_batch(emails, source_type, source_ref, opts \\ []) when is_list(emails) do
    call(:start_batch, [emails, source_type, source_ref, opts], {:error, :unavailable}, fn
      message -> {:error, {:engine_error, message}}
    end)
  end

  @doc "The newest batch of one source, or `nil`."
  @spec latest_batch(String.t(), term()) :: map() | nil
  def latest_batch(source_type, source_ref),
    do: call(:latest_batch, [source_type, source_ref], nil)

  @doc "A batch by uuid, or `nil`."
  @spec get_batch(term()) :: map() | nil
  def get_batch(uuid), do: call(:get_batch, [uuid], nil)

  @doc """
  Subscribes the calling process to a batch's progress. The messages are the
  engine's `{:email_verify_batch, %{uuid:, state:, processed:, total:, counts:}}`.
  """
  @spec subscribe_batch(String.t()) :: :ok | {:error, term()}
  def subscribe_batch(uuid), do: call(:subscribe_batch, [uuid], {:error, :unavailable})

  @doc "The most distinct addresses one batch can hold, or `nil` without the engine."
  @spec max_batch_size() :: pos_integer() | nil
  def max_batch_size, do: call(:max_batch_size, [], nil)

  # Resolved at call time so the tests can stand in for the engine (or for its
  # absence); nothing sets it in a host.
  defp engine do
    Application.get_env(:phoenix_kit_newsletters, :email_verification_engine, @default_engine)
  end

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
      message = Exception.message(e)
      Logger.warning("[Newsletters] email verification #{function} failed: #{message}")
      failure(on_failure, message, default)
  catch
    :exit, reason ->
      Logger.warning("[Newsletters] email verification #{function} exited: #{inspect(reason)}")
      failure(on_failure, "exited: " <> inspect(reason), default)
  end

  defp failure(nil, _message, default), do: default
  defp failure(on_failure, message, _default), do: on_failure.(message)
end
