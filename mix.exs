defmodule Assay.MixProject do
  use Mix.Project

  def project do
    [
      app: :assay,
      version: "0.1.0",
      description: "A tool for running Dialyzer in incremental mode on Elixir projects.",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      assay: assay(),
      test_coverage: [output: "cover"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :dialyzer, :syntax_tools, :tools],
      mod: {Assay.Application, []}
    ]
  end

  defp deps do
    [
      {:file_system, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:igniter, "~> 0.6", optional: true},
      {:erlex, "~> 0.2", optional: true}
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

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/Ch4s3/assay"
      }
    ]
  end
end
