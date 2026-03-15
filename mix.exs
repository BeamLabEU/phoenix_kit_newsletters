defmodule PhoenixKitNewsletters.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_newsletters"

  def project do
    [
      app: :phoenix_kit_newsletters,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description:
        "Newsletters module for PhoenixKit — email broadcasts and subscription management"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:phoenix_kit, "~> 1.7", path: "/app"},
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
      files: ~w(lib mix.exs README.md)
    ]
  end
end
