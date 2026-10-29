defmodule PhoenixKit.Newsletters.EmailVerificationTest do
  @moduledoc """
  The soft bridge to the host-configured verification engine: with no engine
  configured, with a configured module that is not an engine, with an engine
  that breaks, with an engine that implements only the required callbacks, and
  with a scripted stand-in that implements all of them.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Newsletters.EmailVerification
  alias PhoenixKitNewsletters.Test.FakeVerificationEngine, as: Fake

  @engine_key :email_verification_engine

  defp use_engine(module) do
    Application.put_env(:phoenix_kit_newsletters, @engine_key, module)
    on_exit(fn -> Application.delete_env(:phoenix_kit_newsletters, @engine_key) end)
  end

  describe "without an engine configured" do
    setup do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
    end

    test "reads are neutral" do
      refute EmailVerification.available?()
      refute EmailVerification.enabled?()
      refute EmailVerification.queue_configured?()
      assert EmailVerification.results_for(["a@x.com"]) == %{}
      assert EmailVerification.statuses_for(["a@x.com"]) == %{}
      assert EmailVerification.latest_batch("newsletters_crm_list", "ref") == nil
      assert EmailVerification.get_batch(Ecto.UUID.generate()) == nil
      assert EmailVerification.max_batch_size() == nil
      assert EmailVerification.smtp_mode() == "off"
      assert EmailVerification.runner_status() == nil
      assert EmailVerification.settings_path() == nil
      refute EmailVerification.smtp_runner_waiting?()
    end

    test "summary counts everything as unchecked" do
      assert EmailVerification.summary(["a@x.com", "b@x.com"]) ==
               %{valid: 0, invalid: 0, temp: 0, not_sure: 0, unchecked: 2}
    end

    test "actions are unavailable" do
      assert EmailVerification.start_batch(["a@x.com"], "newsletters_crm_list", "ref") ==
               {:error, :unavailable}

      assert EmailVerification.subscribe_batch(Ecto.UUID.generate()) == {:error, :unavailable}
    end
  end

  describe "with a configuration that names no engine" do
    test "a module that is not loaded is not an engine" do
      use_engine(PhoenixKitNewsletters.Test.NoSuchEngine)

      refute EmailVerification.available?()
      refute EmailVerification.enabled?()
      assert EmailVerification.results_for(["a@x.com"]) == %{}

      assert EmailVerification.start_batch(["a@x.com"], "newsletters_crm_list", "ref") ==
               {:error, :unavailable}
    end

    test "a module without the engine's functions is not an engine" do
      use_engine(Enum)
      refute EmailVerification.available?()
      assert EmailVerification.results_for(["a@x.com"]) == %{}
    end

    test "a value that is not a module name reads as no engine, not as a crash" do
      for value <- ["PhoenixKit.Whatever", 42, [:not, :a, :module], %{}] do
        use_engine(value)

        refute EmailVerification.available?(), inspect(value)
        assert EmailVerification.results_for(["a@x.com"]) == %{}, inspect(value)

        assert EmailVerification.start_batch(["a@x.com"], "newsletters_crm_list", "ref") ==
                 {:error, :unavailable},
               inspect(value)
      end
    end
  end

  describe "with an engine that breaks" do
    defmodule Raising do
      def verify(_email, _opts), do: :ok
      def enabled?, do: raise("boom")
      def results_for(_emails), do: raise("boom")
      def start_batch(_emails, _type, _ref, _opts), do: raise("boom")
      def subscribe_batch(_uuid), do: exit(:noproc)
    end

    defmodule Exiting do
      def verify(_email, _opts), do: :ok
      def start_batch(_emails, _type, _ref, _opts), do: exit(:noproc)
    end

    defmodule Rambling do
      def verify(_email, _opts), do: :ok
      def results_for(_emails), do: raise(String.duplicate("a", 100_000) <> "@")
    end

    defmodule Quoting do
      def verify(_email, _opts), do: :ok
      def results_for(_emails), do: raise("insert failed for alice@example.com")
      def subscribe_batch(_uuid), do: exit({:bad, "bob.smith@example.org"})
    end

    setup do
      use_engine(Raising)
    end

    test "a raise is logged and answered with the neutral value" do
      log =
        capture_log(fn ->
          refute EmailVerification.enabled?()
          assert EmailVerification.results_for(["a@x.com"]) == %{}
        end)

      assert log =~ "email verification enabled? failed: boom"
    end

    test "the log lines mask the addresses an engine message quotes" do
      use_engine(Quoting)

      log =
        capture_log(fn ->
          assert EmailVerification.results_for(["alice@example.com"]) == %{}
          assert EmailVerification.subscribe_batch(Ecto.UUID.generate()) == {:error, :unavailable}
        end)

      assert log =~ "a***@example.com"
      assert log =~ "b***@example.org"
      refute log =~ "alice"
      refute log =~ "bob.smith"
    end

    test "masking a very long message without an address stays fast" do
      use_engine(Rambling)

      {microseconds, _log} =
        :timer.tc(fn ->
          capture_log(fn -> assert EmailVerification.results_for(["a@x.com"]) == %{} end)
        end)

      assert microseconds < 2_000_000
    end

    test "a bracketed address is masked inside its brackets" do
      defmodule Bracketed do
        def verify(_email, _opts), do: :ok

        def results_for(_emails),
          do: raise("failed for [john@example.com] and <jane@example.org>")
      end

      use_engine(Bracketed)

      log = capture_log(fn -> EmailVerification.results_for(["a@x.com"]) end)

      assert log =~ "[j***@example.com]"
      assert log =~ "<j***@example.org>"
      refute log =~ "john"
    end

    test "a raise in start_batch is an engine error, not an absent module" do
      log =
        capture_log(fn ->
          assert EmailVerification.start_batch(["a@x.com"], "newsletters_crm_list", "r") ==
                   {:error, {:engine_error, "boom"}}
        end)

      assert log =~ "email verification start_batch failed: boom"
    end

    test "an exit in start_batch is an engine error too" do
      use_engine(Exiting)

      log =
        capture_log(fn ->
          assert {:error, {:engine_error, message}} =
                   EmailVerification.start_batch(["a@x.com"], "newsletters_crm_list", "r")

          assert message =~ "noproc"
        end)

      assert log =~ "start_batch exited"
    end

    test "an exit is answered with the neutral value too" do
      log =
        capture_log(fn ->
          assert EmailVerification.subscribe_batch(Ecto.UUID.generate()) ==
                   {:error, :unavailable}
        end)

      assert log =~ "subscribe_batch exited"
    end
  end

  describe "with an engine release that predates statuses_for/1" do
    defmodule OldEngine do
      def verify(_email, _opts), do: :ok
      def results_for(emails), do: Map.new(emails, &{&1, %{status: "valid", log: []}})
    end

    test "the SMTP stage reads as off: no mode, no runner, nothing to wait for" do
      use_engine(OldEngine)

      assert EmailVerification.available?()
      assert EmailVerification.smtp_mode() == "off"
      assert EmailVerification.runner_status() == nil
      refute EmailVerification.smtp_runner_waiting?()
    end

    test "statuses_for/1 falls back to results_for/1" do
      use_engine(OldEngine)

      assert EmailVerification.statuses_for(["a@x.com"]) ==
               %{"a@x.com" => %{status: "valid", log: []}}
    end
  end

  describe "with an engine that implements only the required callbacks" do
    defmodule Minimal do
      @behaviour PhoenixKit.Newsletters.VerificationEngine

      @impl true
      def verify(_email, _opts), do: {:ok, %{status: "valid"}}
      @impl true
      def enabled?, do: true
      @impl true
      def queue_configured?, do: true
      @impl true
      def results_for(emails), do: Map.new(emails, &{&1, %{status: "valid", reason: nil}})
      @impl true
      def summary(emails),
        do: %{valid: length(emails), invalid: 0, temp: 0, not_sure: 0, unchecked: 0}

      @impl true
      def start_batch(emails, _type, _ref, _opts), do: {:ok, %{uuid: "b", total: length(emails)}}
      @impl true
      def latest_batch(_type, _ref), do: nil
      @impl true
      def get_batch(_uuid), do: nil
      @impl true
      def subscribe_batch(_uuid), do: :ok
      @impl true
      def max_batch_size, do: 10
    end

    setup do
      use_engine(Minimal)
    end

    test "is an engine, and the required callbacks are forwarded" do
      assert EmailVerification.available?()
      assert EmailVerification.enabled?()
      assert EmailVerification.queue_configured?()
      assert EmailVerification.max_batch_size() == 10
      assert EmailVerification.subscribe_batch("u") == :ok
    end

    test "the optional callbacks it lacks read as neutral values" do
      assert EmailVerification.smtp_mode() == "off"
      assert EmailVerification.runner_status() == nil
      assert EmailVerification.settings_path() == nil
      refute EmailVerification.smtp_runner_waiting?()
    end

    test "statuses_for/1 falls back to results_for/1" do
      assert EmailVerification.statuses_for(["a@x.com"]) ==
               %{"a@x.com" => %{status: "valid", reason: nil}}
    end
  end

  describe "with a scripted engine" do
    setup do
      use_engine(Fake)
    end

    test "forwards every call" do
      Fake.put(:results, %{"a@x.com" => %{status: "valid"}})
      Fake.put(:enabled, true)

      assert EmailVerification.available?()
      assert EmailVerification.enabled?()

      assert EmailVerification.results_for(["a@x.com", "b@x.com"]) == %{
               "a@x.com" => %{status: "valid"}
             }

      assert EmailVerification.summary(["a@x.com", "b@x.com"]) ==
               %{valid: 1, invalid: 0, temp: 0, not_sure: 0, unchecked: 1}

      assert {:ok, %{total: 1}} =
               EmailVerification.start_batch(["a@x.com"], "newsletters_user_group", "ref",
                 title: "T"
               )

      assert_received {:start_batch, ["a@x.com"], "newsletters_user_group", "ref", [title: "T"]}

      assert EmailVerification.subscribe_batch("u") == :ok
      assert_received {:subscribe_batch, "u"}
      assert EmailVerification.max_batch_size() == 100
    end

    test "smtp_mode/0 and runner_status/0 forward to the engine" do
      Fake.put(:smtp_mode, "runner")
      Fake.put(:runner_status, %{state: :online})

      assert EmailVerification.smtp_mode() == "runner"
      assert EmailVerification.runner_status() == %{state: :online}
    end

    test "smtp_runner_waiting?/1 is true only in runner mode with a runner that is not online" do
      Fake.put(:smtp_mode, "runner")

      for state <- [:never_connected, :offline] do
        Fake.put(:runner_status, %{state: state})
        assert EmailVerification.smtp_runner_waiting?(), inspect(state)
      end

      Fake.put(:runner_status, %{state: :online})
      refute EmailVerification.smtp_runner_waiting?()

      for mode <- ["off", "local"] do
        Fake.put(:smtp_mode, mode)
        Fake.put(:runner_status, %{state: :offline})
        refute EmailVerification.smtp_runner_waiting?(), mode
      end
    end

    test "settings_path/0 forwards the path of the engine's settings page" do
      assert EmailVerification.settings_path() == nil

      Fake.put(:settings_path, "/admin/verification/settings")
      assert EmailVerification.settings_path() == "/admin/verification/settings"
    end

    test "settings_path/0 passes on any absolute path of this site" do
      for value <- ["/", "/admin/verification/settings", "/admin/x?tab=smtp&a=b%20c", "/x#runner"] do
        Fake.put(:settings_path, value)
        assert EmailVerification.settings_path() == value, inspect(value)
      end
    end

    test "settings_path/0 passes on nothing a browser could read as another site" do
      refused = [
        nil,
        42,
        "",
        "settings",
        " /x",
        "https://example.com/settings",
        "//example.com",
        # A browser drops a tab, a newline and a carriage return anywhere in a URL
        # and reads a backslash as a slash: each of these is `//example.com` to it.
        "/\\example.com",
        "/\t/example.com",
        "/\n/example.com",
        "/\r/example.com",
        "/x\\y",
        "/x\ty",
        "/x y",
        "/x\0y",
        "/x\x7fy",
        "/x\n"
      ]

      for value <- refused do
        Fake.put(:settings_path, value)
        assert EmailVerification.settings_path() == nil, inspect(value)
      end
    end

    test "an unreadable runner status is not a reason to warn" do
      Fake.put(:smtp_mode, "runner")
      Fake.put(:runner_status, nil)
      refute EmailVerification.smtp_runner_waiting?()
    end

    test "statuses_for/1 asks the engine for the statuses, not the full verdicts" do
      Fake.put(:results, %{"a@x.com" => %{status: "valid", level: "smtp", log: [:big]}})

      assert EmailVerification.statuses_for(["a@x.com", "b@x.com"]) ==
               %{"a@x.com" => %{status: "valid", level: "smtp"}}

      assert_received {:statuses_for, ["a@x.com", "b@x.com"]}
      refute_received {:results_for, _}
    end

    test "passes an engine error through untouched" do
      Fake.put(:start_batch, {:error, :too_many_emails})

      assert EmailVerification.start_batch(["a@x.com"], "newsletters_crm_list", "r") ==
               {:error, :too_many_emails}
    end
  end
end
