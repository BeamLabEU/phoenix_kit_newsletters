require Logger

# Start the embedded test repo and bring it to the current PhoenixKit
# schema version, so tests exercising Settings/Integrations/SendProfile
# (e.g. D2 SendProfile CRUD, D4 profile-aware delivery) have a real DB to
# round-trip against. Mirrors core phoenix_kit's test_helper.exs db_check
# and phoenix_kit_emails' test_helper.exs; tests tagged :integration are
# excluded when no test DB is reachable.
repo_available =
  try do
    {:ok, _} = PhoenixKitNewsletters.Test.Repo.start_link()
    PhoenixKit.Migration.ensure_current(PhoenixKitNewsletters.Test.Repo, log: false)
    Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitNewsletters.Test.Repo, :manual)
    true
  rescue
    e ->
      IO.puts("""
      \n⚠  Could not connect to test database — integration tests will be excluded.
         Run `createdb phoenix_kit_newsletters_test` to create it.
         Error: #{Exception.message(e)}
      """)

      false
  catch
    :exit, reason ->
      IO.puts("""
      \n⚠  Could not connect to test database — integration tests will be excluded.
         Run `createdb phoenix_kit_newsletters_test` to create it.
         Error: #{inspect(reason)}
      """)

      false
  end

exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
