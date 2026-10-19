defmodule PhoenixKit.Newsletters.EmailVerificationTest do
  @moduledoc """
  The soft bridge to the Emails module's verification engine: with the engine
  absent, with an engine that breaks, with a scripted stand-in, and (tagged,
  skipped when `phoenix_kit_emails` has no engine) with the real one.
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

  describe "without the engine" do
    setup do
      use_engine(PhoenixKit.Modules.Emails.NoSuchVerification)
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

    test "a module without the engine's functions is not an engine" do
      use_engine(Enum)
      refute EmailVerification.available?()
      assert EmailVerification.results_for(["a@x.com"]) == %{}
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

    test "statuses_for/1 falls back to results_for/1" do
      use_engine(OldEngine)

      assert EmailVerification.statuses_for(["a@x.com"]) ==
               %{"a@x.com" => %{status: "valid", log: []}}
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

  describe "with the real engine" do
    @describetag :requires_emails_verification

    # Not an alias: without the engine in the build the module does not exist, and a
    # literal call would be a compile warning in a suite that skips these tests.
    defp engine, do: Module.concat(["PhoenixKit.Modules.Emails.Verification"])

    test "is available and enabled by default, and reports the Oban queue honestly" do
      assert EmailVerification.available?()
      assert EmailVerification.enabled?()
      # The test host declares no Oban queues of its own.
      refute EmailVerification.queue_configured?()
    end

    test "results_for/1 and summary/1 read what the engine stored" do
      {:ok, _} = engine().verify("someone@example.com")
      {:ok, _} = engine().verify("not-an-address")

      emails = ["someone@example.com", "never-checked@example.com"]

      assert %{"someone@example.com" => %{status: "not_sure", level: "mx"}} =
               EmailVerification.results_for(emails)

      assert EmailVerification.summary(emails) ==
               %{valid: 0, invalid: 0, temp: 0, not_sure: 1, unchecked: 1}
    end

    test "statuses_for/1 reads the stored status and reason without the step log" do
      {:ok, _} = engine().verify("someone@example.com")

      assert %{"someone@example.com" => info} =
               map = EmailVerification.statuses_for(["someone@example.com", "never@example.com"])

      assert %{status: "not_sure", level: "mx"} = info
      refute Map.has_key?(info, :log)
      refute Map.has_key?(map, "never@example.com")
    end

    test "start_batch/4, latest_batch/2 and get_batch/1 round-trip through the engine" do
      start_supervised!(
        {Oban,
         repo: PhoenixKitNewsletters.Test.Repo, testing: :manual, queues: [], plugins: false}
      )

      assert {:ok, batch} =
               EmailVerification.start_batch(
                 ["a@example.com", "b@example.com"],
                 "newsletters_crm_list",
                 "list-1"
               )

      assert batch.total == 2
      assert EmailVerification.latest_batch("newsletters_crm_list", "list-1").uuid == batch.uuid
      assert EmailVerification.get_batch(batch.uuid).uuid == batch.uuid
      assert EmailVerification.latest_batch("newsletters_crm_list", "other") == nil
      assert EmailVerification.subscribe_batch(batch.uuid) == :ok
    end

    test "start_batch/4 with nothing to verify is the engine's own error" do
      assert EmailVerification.start_batch([], "newsletters_crm_list", "r") ==
               {:error, :no_emails}
    end
  end
end
