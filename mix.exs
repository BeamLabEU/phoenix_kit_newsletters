defmodule PhoenixKitNewsletters.MixProject do
  use Mix.Project

  @version "0.1.5"
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
