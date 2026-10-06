defmodule PhoenixKitNewsletters.MixProject do
  use Mix.Project

  @version "0.4.2"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_newsletters"

  def project do
    [
      app: :phoenix_kit_newsletters,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description:
        "Newsletters module for PhoenixKit — email broadcasts and subscription management",

      # Dialyzer
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"],

      # Docs
      name: "PhoenixKitNewsletters",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :gettext],
      # The only process this package owns is the attachment cache's ETS
      # table owner — see PhoenixKit.Newsletters.Application.
      mod: {PhoenixKit.Newsletters.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  defp deps do
    [
      # Core
      # 2.48 is the first core with `PhoenixKit.Email.Layout.render_parts/2`,
      # the header/footer a broadcast layout places as {{{header}}} and
      # {{{footer}}}; 2.52 is the first whose `ExpectedSchema` manifest no
      # longer declares `fk_newsletters_broadcasts_template` (#896), the FK
      # migration V2 re-targets at the layouts table — see
      # `PhoenixKitNewsletters.Migrations`' moduledoc ("Core's manifest").
      {:phoenix_kit, "~> 2.52"},
      # `PhoenixKit.Templates.Substitution` is called directly (the one
      # substitution pass a broadcast gets), so it is declared rather than
      # reached through core.
      {:phoenix_kit_templates, "~> 0.2.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:gettext, "~> 1.0"},
      {:oban, "~> 2.20"},
      {:mdex, "~> 0.13"},
      {:uuidv7, "~> 1.0"},

      # Optional rustler pin so the transitive `mdex_native` NIF can
      # source-build on hosts where its precompiled variant doesn't
      # match the local NIF version. Matches the parent app's pin.
      {:rustler, ">= 0.0.0", optional: true},

      # Dev/test
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Test-only — CRMSource resolves PhoenixKitCRM.Lists/Contacts at
      # runtime via Code.ensure_loaded?/1 (soft dependency, not required in
      # a host app), but its correctness is only exercisable against the
      # real CRM schema+context. Core's own migrations create the CRM
      # tables (V138+); this just makes the Elixir modules loadable so the
      # test suite can build real fixtures instead of only covering the
      # "CRM not installed" degrade path. The contact-lists feature
      # (Lists/ContactList/ListMember) shipped upstream in 0.3.0.
      {:phoenix_kit_crm, "~> 0.6", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKit.Newsletters",
      # Tags in this repo are bare version numbers, not v-prefixed — a "v" ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: @version,
      source_url: @source_url
    ]
  end
end
