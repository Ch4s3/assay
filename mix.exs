defmodule Assay.MixProject do
  use Mix.Project

  def project do
    [
      app: :assay,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      assay: assay()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :dialyzer, :syntax_tools],
      mod: {Assay.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp assay do
    [
      dialyzer: [
        apps: assay_apps(),
        warning_apps: [:assay]
      ]
    ]
  end

  defp assay_apps do
    [
      :assay,
      :dialyzer,
      :mix,
      :compiler,
      :syntax_tools,
      :logger,
      :kernel,
      :stdlib,
      :elixir,
      :erts
    ]
  end
end
