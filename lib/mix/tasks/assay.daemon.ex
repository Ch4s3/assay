defmodule Mix.Tasks.Assay.Daemon do
  @moduledoc false

  use Mix.Task

  @shortdoc "Run Assay as a JSON-RPC daemon"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")
    Assay.Daemon.serve()
  end
end
