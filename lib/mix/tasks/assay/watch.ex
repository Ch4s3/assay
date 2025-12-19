defmodule Mix.Tasks.Assay.Watch do
  @moduledoc false
  use Mix.Task

  @shortdoc "Watch project files and rerun incremental Dialyzer on change"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Assay.Watch.run()
  end
end
