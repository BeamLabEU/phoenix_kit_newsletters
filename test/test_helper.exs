require Logger

# Start the embedded test repo and bring it to the current PhoenixKit
# schema version, so tests exercising Settings/Integrations/core
# Email.SendProfile (e.g. D4 profile-aware delivery) have a real DB to
# round-trip against. Mirrors core phoenix_kit's test_helper.exs db_check
# and phoenix_kit_emails' test_helper.exs; tests tagged :integration are
# excluded when no test DB is reachable.
repo_available =
  try do
    {:ok, _} = PhoenixKitNewsletters.Test.Repo.start_link()
    PhoenixKit.Migration.ensure_current(PhoenixKitNewsletters.Test.Repo, log: false)
    Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitNewsletters.Test.Repo, :manual)
    # PhoenixKit.Users.Roles.create_role/update_role/delete_role broadcast
    # through this (Admin.Events.broadcast_role_created/2 etc) — needed by
    # UserGroupSourceTest's role-management fixtures. Mirrors core
    # phoenix_kit's own test_helper.exs, which starts this for the same
    # reason.
    {:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
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

# Broadcast.attachments (core V158, PR#661) isn't in a hex phoenix_kit
# release yet — only a small minority of :integration tests actually need
# the column (the rest touch unrelated tables), so this is its own
# exclusion tag rather than folding into :integration wholesale, which
# would exclude far more than necessary. Checked via a real query, not a
# version-string comparison, so it stays correct if the reader IS running
# against a local V158 core (path/git override) with a hex version string
# that predates it.
v158_available =
  if repo_available do
    Ecto.Adapters.SQL.Sandbox.checkout(PhoenixKitNewsletters.Test.Repo)

    result =
      case PhoenixKitNewsletters.Test.Repo.query(
             "SELECT 1 FROM information_schema.columns WHERE table_name = 'phoenix_kit_newsletters_broadcasts' AND column_name = 'attachments'"
           ) do
        {:ok, %{rows: [_ | _]}} -> true
        _ -> false
      end

    Ecto.Adapters.SQL.Sandbox.checkin(PhoenixKitNewsletters.Test.Repo)
    result
  else
    false
  end

unless v158_available do
  IO.puts("""
  \n⚠  core V158 (phoenix_kit_newsletters_broadcasts.attachments column) not
     present in this test DB — tests tagged :requires_v158 are excluded.
     Not yet in a hex phoenix_kit release; run against a local V158 core
     build (path/git override) to exercise them for real.
  """)
end

exclude =
  if(repo_available, do: [], else: [:integration]) ++
    if v158_available, do: [], else: [:requires_v158]

ExUnit.start(exclude: exclude)
