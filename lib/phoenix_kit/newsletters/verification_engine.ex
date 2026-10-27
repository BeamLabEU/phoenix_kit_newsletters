defmodule PhoenixKit.Newsletters.VerificationEngine do
  @moduledoc """
  The contract of an address verification engine: the module that checks
  whether an email address can be mailed, which **Newsletters → Address
  verification** drives.

  Newsletters ships no engine and depends on none. The host names the module
  that plays this part:

      # config/config.exs
      config :phoenix_kit_newsletters, :email_verification_engine, MyApp.AddressVerification

  With nothing configured (or a module that is not loaded, or one without
  `verify/2`) the page says that no engine is configured and every call of
  `PhoenixKit.Newsletters.EmailVerification` answers a neutral value. The
  module does not have to declare `@behaviour`: the bridge is duck-typed and
  checks `function_exported?/3` before each call. Declaring it gets the
  compiler to check the callbacks and their arities.

  ## Required and optional callbacks

  `verify/2` is the one function that marks a module as an engine; the page
  calls the others as it needs them. An engine that lacks a callback does not
  crash the page: the bridge answers that callback with a neutral value.

  The optional callbacks (`statuses_for/1`, `smtp_mode/0`, `runner_status/0`,
  `settings_path/0`) are the ones an older engine release may not have yet:

    * without `statuses_for/1` the page filters on `results_for/1`, which
      returns the same verdicts with their step logs;
    * without `smtp_mode/0` the SMTP mode reads `"off"`;
    * without `runner_status/0` the runner reads as unknown (`nil`), so the
      page never claims a runner is offline;
    * without `settings_path/0` the page has no settings page to point at and
      shows its hints as plain text.

  ## Verdicts

  `results_for/1` returns a `t:verdict/0` per verified address, keyed by the
  address as given; an address never verified is absent. A verdict is a map
  (or a struct) with a `:status` of `"valid"`, `"invalid"`, `"temp"` or
  `"not_sure"`; anything else reads as not checked. The page also reads, when
  present, `:reason` (a short code the page labels; an unknown code is shown
  as it is), `:level` (`"mx"` for an address whose domain accepts mail but
  whose mailbox was not probed), the flags `:free`, `:role` and `:disposable`,
  and `:checked_at` (a `DateTime`).

  `statuses_for/1` returns the same map without the step logs — only
  `:status`, `:reason` and `:level` are read from it.

  ## Batches

  `start_batch/4` stores a background batch for a list of addresses and returns
  it. The page starts one per audience: `source_type` is
  `"newsletters_crm_list"` (the `source_ref` is the list's uuid) or
  `"newsletters_user_group"` (the `source_ref` is `"roles:"` and a digest of the
  sorted role uuids), and `opts` carries `:title` and `:created_by_uuid`, either
  of which may be `nil`. The engine answers `{:error, :no_emails}` for an empty
  list and `{:error, :too_many_emails}` above `max_batch_size/0`; any other
  `{:error, reason}` reads as "could not start". `latest_batch/2` finds the
  newest batch of a source again when the page is opened later.

  A `t:batch/0` is a map (or struct) with `:uuid`, `:state` (`"queued"`,
  `"running"`, `"done"` or `"cancelled"`), `:processed`, `:total`, `:counts` and
  `:finished_at`. A batch whose addresses wait for an SMTP stage also carries
  `:awaiting_smtp`.

  ## Progress messages

  `subscribe_batch/1` subscribes the calling process to one batch. From then on
  it receives

      {:email_verify_batch, %{uuid: uuid, state: state, processed: n, total: n, counts: counts}}

  (`t:progress_message/0`; `:awaiting_smtp` may be added). The last message of a
  batch has `state: "done"` or `"cancelled"`. Workers run in parallel, so a
  message can arrive after a newer one; the page ignores a snapshot whose
  `:processed` is lower than the one it holds and re-reads the batch with
  `get_batch/1` when a batch ends. The message tag, the keys and the batch states
  are a compatibility surface: change them only additively.

  ## The SMTP stage

  An engine that probes mailboxes over SMTP may hand that work to a remote
  runner. `smtp_mode/0` is `"off"`, `"runner"` or `"local"`; in `"runner"` mode
  `runner_status/0` returns a map whose `:state` is `:online`, `:offline` or
  `:never_connected`. While a batch runs and the mode is `"runner"` with a runner
  that is not online, the page tells the operator that SMTP is waiting, and links
  to the engine's settings page when `settings_path/0` gives one (the runner is
  configured there, not in Newsletters). An address parked for that stage has the
  verdict `status: "not_sure"` with `reason: "smtp_pending"`.
  """

  @typedoc "An address as the page passes it: the sendable address of the audience."
  @type email :: String.t()

  @typedoc """
  A stored verdict. Only `:status` is required; see the module documentation for
  the keys the page reads when they are there.
  """
  @type verdict :: %{
          required(:status) => String.t(),
          optional(:reason) => String.t() | nil,
          optional(:level) => String.t() | nil,
          optional(:free) => boolean(),
          optional(:role) => boolean(),
          optional(:disposable) => boolean(),
          optional(:checked_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "A verdict without the step logs, as `statuses_for/1` returns it."
  @type status_info :: %{
          required(:status) => String.t(),
          optional(:reason) => String.t() | nil,
          optional(:level) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "Counts of an audience's addresses by stored status; `:unchecked` has no verdict."
  @type summary :: %{
          valid: non_neg_integer(),
          invalid: non_neg_integer(),
          temp: non_neg_integer(),
          not_sure: non_neg_integer(),
          unchecked: non_neg_integer()
        }

  @typedoc "A stored batch."
  @type batch :: %{
          required(:uuid) => String.t(),
          required(:state) => String.t(),
          required(:processed) => non_neg_integer(),
          required(:total) => non_neg_integer(),
          required(:counts) => map(),
          required(:finished_at) => DateTime.t() | nil,
          optional(:awaiting_smtp) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @typedoc "The snapshot a progress message carries."
  @type progress :: %{
          required(:uuid) => String.t(),
          required(:state) => String.t(),
          required(:processed) => non_neg_integer(),
          required(:total) => non_neg_integer(),
          required(:counts) => map(),
          optional(:awaiting_smtp) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @typedoc "What `subscribe_batch/1` makes the engine send to the subscriber."
  @type progress_message :: {:email_verify_batch, progress()}

  @typedoc "The options `start_batch/4` is called with."
  @type batch_opts :: [title: String.t() | nil, created_by_uuid: String.t() | nil]

  @doc """
  Verifies one address and returns the verdict. Its presence marks the module as
  an engine; the page itself does not call it.
  """
  @callback verify(email(), keyword()) :: {:ok, verdict()} | {:error, term()}

  @doc """
  Whether the engine is switched on. When it is not, the page says verification
  is switched off and does not offer to start a batch. How the engine is
  switched on is its own business.
  """
  @callback enabled?() :: boolean()

  @doc """
  Whether the host runs the Oban queue the engine's batches need. `false` makes
  the page warn that a started batch would never run.
  """
  @callback queue_configured?() :: boolean()

  @doc "Stored verdicts by address, keyed by the address as given; never-verified addresses are absent."
  @callback results_for([email()]) :: %{email() => verdict()}

  @doc """
  Stored `:status`, `:reason` and `:level` by address, without the step logs: for
  filtering and counting a whole audience. Optional; the page falls back to
  `results_for/1`.
  """
  @callback statuses_for([email()]) :: %{email() => status_info()}

  @doc "Counts of the addresses by stored status; an address with no verdict is `:unchecked`."
  @callback summary([email()]) :: summary()

  @doc """
  Starts a background batch for the addresses and returns the stored batch. See
  the module documentation for `source_type`, `source_ref`, `opts` and the errors
  the page tells apart.
  """
  @callback start_batch([email()], source_type :: String.t(), source_ref :: term(), batch_opts()) ::
              {:ok, batch()} | {:error, term()}

  @doc "The newest batch of one source, or `nil`."
  @callback latest_batch(source_type :: String.t(), source_ref :: term()) :: batch() | nil

  @doc "A batch by uuid, or `nil`."
  @callback get_batch(uuid :: term()) :: batch() | nil

  @doc """
  Subscribes the calling process to the batch's progress messages
  (`t:progress_message/0`).
  """
  @callback subscribe_batch(uuid :: String.t()) :: :ok | {:error, term()}

  @doc "The most distinct addresses one batch can hold; `start_batch/4` refuses more."
  @callback max_batch_size() :: pos_integer()

  @doc """
  The SMTP mode: `"off"`, `"runner"` or `"local"`. Optional; read as `"off"`
  without it.
  """
  @callback smtp_mode() :: String.t()

  @doc """
  What the engine knows about its SMTP runner: a map with at least `:state`
  (`:online`, `:offline` or `:never_connected`). Optional; read as unknown
  without it.
  """
  @callback runner_status() :: map()

  @doc """
  The path of the engine's own settings page (for example
  `PhoenixKit.Utils.Routes.path("/admin/verification/settings")`), or `nil` when
  it has none. The page links to it from the SMTP-runner hint; only an absolute
  path of this site (starting with a single `/`) is used. Optional; read as `nil`
  without it.
  """
  @callback settings_path() :: String.t() | nil

  @optional_callbacks statuses_for: 1, smtp_mode: 0, runner_status: 0, settings_path: 0
end
