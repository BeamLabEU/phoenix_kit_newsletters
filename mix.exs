defmodule PhoenixKitNewsletters.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_newsletters"

  def project do
    [
      app: :phoenix_kit_newsletters,
      name: "PhoenixKitNewsletters",
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      description:
        "Newsletters module for PhoenixKit — email broadcasts and subscription management"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # path: "/app" is temporary — remove once phoenix_kit >= 1.7.73 is published to Hex
      {:phoenix_kit, "~> 1.7.73", path: "/app"},
      {:phoenix_live_view, "~> 1.1"},
      {:oban, "~> 2.20"},
      {:earmark, "~> 1.4"},
      {:uuidv7, "~> 1.0"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKit.Modules.Newsletters",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
