defmodule Mix.Tasks.Assay do
  @moduledoc false
  use Mix.Task

  @shortdoc "Run incremental Dialyzer using the host project's mix.exs config"

  @impl true
  def run(_args) do
    case Assay.run() do
      :ok ->
        :ok

      :warnings ->
        Mix.shell().info("Dialyzer reported warnings")
        exit({:shutdown, 1})
    end
  end
end
