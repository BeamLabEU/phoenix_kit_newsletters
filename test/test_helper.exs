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

    # The tables other modules own (core 3.0 no longer creates them): their real
    # chains, in dependency order.
    for chain <- [PhoenixKitCRM.Migrations],
        stmt <- chain.up_statements("public") do
      PhoenixKitNewsletters.Test.Repo.query!(stmt)
    end

    # This module's own chain (PhoenixKitNewsletters.Migrations) stamps
    # phoenix_kit_newsletters_broadcasts with pknl_schema:1 on top of what
    # core's chain above already created — every test run starts from a
    # database at this chain's current version, not just core's.
    PhoenixKitNewsletters.Migrations.up_statements()
    |> Enum.each(&Ecto.Adapters.SQL.query!(PhoenixKitNewsletters.Test.Repo, &1, []))

    # The Emails module's own chain, when the address-verification engine is
    # loaded (test-only dep; PHOENIX_KIT_EMAILS_PATH points at a checkout that
    # has it): its V4 creates the verification tables the real-engine tests
    # read and write. Same raw-statements approach as above.
    if Code.ensure_loaded?(PhoenixKit.Modules.Emails.Verification) do
      PhoenixKit.Modules.Emails.Migrations.up_statements()
      |> Enum.each(&Ecto.Adapters.SQL.query!(PhoenixKitNewsletters.Test.Repo, &1, []))
    end

    Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitNewsletters.Test.Repo, :manual)
    # PhoenixKit.Users.Roles.create_role/update_role/delete_role broadcast
    # through this (Admin.Events.broadcast_role_created/2 etc) — needed by
    # UserGroupSourceTest's role-management fixtures. Mirrors core
    # phoenix_kit's own test_helper.exs, which starts this for the same
    # reason.
    {:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

    # `Scope.can?/2` asks the module registry whether a key's module is on,
    # and `grant_permission/3` validates keys against it: the permission
    # checks (`newsletters.send`, `newsletters.audiences`, CRM's `crm`) need
    # both modules registered.
    {:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

    for mod <- [PhoenixKit.Newsletters, PhoenixKitCRM],
        Code.ensure_loaded?(mod),
        mod not in PhoenixKit.ModuleRegistry.all_modules() do
      :ok = PhoenixKit.ModuleRegistry.register(mod)
    end

    # Endpoint behind the dead-render tests (test/support/dead_render_*.ex).
    {:ok, _pid} = PhoenixKitNewsletters.Test.DeadRenderEndpoint.start_link()
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

# The verification engine ships in a phoenix_kit_emails release newer than the
# one on Hex today; tests that drive the real engine are tagged
# :requires_emails_verification and skip cleanly when it is not loaded (run the
# suite with PHOENIX_KIT_EMAILS_PATH=<emails checkout> to include them).
emails_verification_available =
  Code.ensure_loaded?(PhoenixKit.Modules.Emails.Verification) and
    function_exported?(PhoenixKit.Modules.Emails.Verification, :start_batch, 4)

unless emails_verification_available do
  IO.puts("""
  \n⚠  PhoenixKit.Modules.Emails.Verification not loaded — tests tagged
     :requires_emails_verification are excluded. Run with
     PHOENIX_KIT_EMAILS_PATH=<phoenix_kit_emails checkout> to exercise them.
  """)
end

# The SMTP stage (`smtp_mode/0`, `runner_status/0`) is newer still: a checkout
# with the engine but without it is the hex 0.5.x shape.
emails_smtp_available =
  emails_verification_available and
    function_exported?(PhoenixKit.Modules.Emails.Verification, :smtp_mode, 0) and
    function_exported?(PhoenixKit.Modules.Emails.Verification, :runner_status, 0)

if emails_verification_available and not emails_smtp_available do
  IO.puts("""
  \n⚠  The loaded Emails verification engine has no SMTP stage (smtp_mode/0,
     runner_status/0) — tests tagged :requires_emails_smtp are excluded.
  """)
end

exclude =
  if(repo_available, do: [], else: [:integration]) ++
    if(v158_available, do: [], else: [:requires_v158]) ++
    if(emails_verification_available, do: [], else: [:requires_emails_verification]) ++
    if emails_smtp_available, do: [], else: [:requires_emails_smtp]

# The builds-alone test needs `PhoenixKit.TestSupport.ModuleChainCheck`, which
# ships in the first core release after 2.64.1; against an older core it is
# excluded.
chain_check_exclude =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck),
    do: [],
    else: [:requires_module_chain_check]

ExUnit.start(exclude: chain_check_exclude ++ exclude)

# The manifest test builds the module's tables with `ModuleChainCheck.build_alone/4`
# and hands the manifest to repair (`PhoenixKit.Module.expected_schema/0`); both
# arrive in the first core release after 2.64.1.
unless Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck) and
         function_exported?(PhoenixKit.TestSupport.ModuleChainCheck, :build_alone, 4) do
  ExUnit.configure(exclude: [:requires_core_expected_schema | ExUnit.configuration()[:exclude]])
end
