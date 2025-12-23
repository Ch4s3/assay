defmodule Assay do
  @moduledoc """
  Public entrypoints for running incremental Dialyzer via Assay.
  """

  alias Assay.Config
  alias Assay.Runner

  @doc """
  Runs incremental Dialyzer using configuration sourced from the host project.

  Returns `:ok` when Dialyzer finishes cleanly, `:warnings` when incremental
  Dialyzer exits with code 1, and raises on any other exit.
  """
  @spec run(keyword()) :: Runner.run_result()
  def run(opts \\ []) do
    config_module = Application.get_env(:assay, :config_module, Config)
    runner_module = Application.get_env(:assay, :runner_module, Runner)

    config = config_module.from_mix_project(opts)
    runner_module.run(config, opts)
  end
end
