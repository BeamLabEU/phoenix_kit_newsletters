defmodule PhoenixKit.Newsletters.VerificationEngineTest do
  @moduledoc """
  The engine contract: which callbacks an engine must have, which it may lack,
  and that the test fake — the one engine this suite ships — keeps up with it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.VerificationEngine
  alias PhoenixKitNewsletters.Test.FakeVerificationEngine, as: Fake

  @required [
    verify: 2,
    enabled?: 0,
    queue_configured?: 0,
    results_for: 1,
    summary: 1,
    start_batch: 4,
    latest_batch: 2,
    get_batch: 1,
    subscribe_batch: 1,
    max_batch_size: 0
  ]

  # Added to engines after their first release; the bridge reads them as neutral
  # values when an engine lacks them.
  @optional [statuses_for: 1, smtp_mode: 0, runner_status: 0]

  test "declares the callbacks the bridge calls, with the engines' existing arities" do
    assert Enum.sort(VerificationEngine.behaviour_info(:callbacks)) ==
             Enum.sort(@required ++ @optional)
  end

  test "an engine may lack the callbacks added after its first release, and only those" do
    assert Enum.sort(VerificationEngine.behaviour_info(:optional_callbacks)) ==
             Enum.sort(@optional)
  end

  test "the test fake declares the behaviour and implements every callback" do
    behaviours = Fake.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    assert VerificationEngine in behaviours

    for {function, arity} <- @required ++ @optional do
      assert function_exported?(Fake, function, arity), "#{function}/#{arity}"
    end
  end
end
