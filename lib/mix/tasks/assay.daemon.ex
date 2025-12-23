defmodule Mix.Tasks.Assay.Daemon do
  @moduledoc false

  use Mix.Task

  @shortdoc "Run Assay as a JSON-RPC daemon"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")
    daemon_module().serve()
  end

  defp daemon_module do
    Application.get_env(:assay, :daemon_module, Assay.Daemon)
  end
end
