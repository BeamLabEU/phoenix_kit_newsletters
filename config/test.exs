import Config

# Embedded test repo for library-level integration tests (mirrors core
# phoenix_kit's config/test.exs and phoenix_kit_emails' config/test.exs).
# D2/D4 need real SendProfile/Broadcast DB round-trips, which this
# package had no test DB for until now.
config :phoenix_kit_newsletters, ecto_repos: [PhoenixKitNewsletters.Test.Repo]

config :phoenix_kit_newsletters, PhoenixKitNewsletters.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_newsletters_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire the repo for phoenix_kit library code that calls
# PhoenixKit.Config.get_repo/0 (Settings, Integrations, etc).
config :phoenix_kit, repo: PhoenixKitNewsletters.Test.Repo

config :logger, level: :warning

# Integrations credentials (e.g. an aws_ses/smtp/brevo_api connection
# referenced by a SendProfile) are only encrypted at rest when a
# secret_key_base is configured — set one so D2's tests can assert the
# real enc:v1: round-trip instead of a no-op passthrough.
config :phoenix_kit,
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_kit_newsletters_tests"

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# D4's legacy (no send profile) DeliveryWorker path calls
# PhoenixKit.Mailer.deliver_email/1, which resolves its adapter from this
# config — route it to the Test adapter so backward-compat tests can
# assert on the captured email. The profile-routed path is unaffected:
# deliver_via_integration/3 resolves a real adapter from the integration's
# stored provider regardless of this setting.
config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Test

# DeliveryWorker.build_variables/2 signs an unsubscribe token via
# Phoenix.Token.sign(PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint), ...),
# which needs a running Endpoint process by default — this package ships
# none standalone. Phoenix.Token's `context` type also accepts a raw
# secret string directly (Phoenix.Token.sign/4 docs), which needs no
# running process, so point :endpoint at one instead of a module.
config :phoenix_kit,
  endpoint: "test_endpoint_secret_key_base_at_least_64_bytes_long_for_newsletters_tests"
