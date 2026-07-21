defmodule PhoenixKitNewsletters.MixProject do
  use Mix.Project

  @version "0.1.8"
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
      dialyzer: [plt_add_apps: [:phoenix_kit], ignore_warnings: ".dialyzer_ignore.exs"],

      # Docs
      name: "PhoenixKitNewsletters",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext]]
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
      # SendProfile/ProviderOptions and the send-profile context moved to
      # `PhoenixKit.Email` in core migration V151 (unreleased as of
      # 2026-07-15) — this package now calls those core modules directly
      # instead of owning its own copies. Bump the floor below to the exact
      # hex version once core cuts a release containing V151; until then,
      # a core built from `feature/email-send-profiles-core` (or later) is
      # required, wired in via a path/git dependency during this rollout.
      {:phoenix_kit, "~> 1.7 and >= 1.7.190"},
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
      {:phoenix_kit_crm, "~> 0.3", only: :test}
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
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
