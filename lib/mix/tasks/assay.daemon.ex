defmodule Mix.Tasks.Assay.Daemon do
  @moduledoc """
  Run Assay as a JSON-RPC daemon over stdio.

  The daemon speaks line-delimited JSON-RPC. Each request must be a single JSON
  object terminated by a newline. Responses are emitted in the same format.

  ## Supported Methods

  * `assay/analyze` - Triggers an incremental Dialyzer run and returns structured diagnostics
  * `assay/getStatus` - Reports daemon status and last run result
  * `assay/getConfig` - Returns current configuration (including overrides)
  * `assay/setConfig` - Applies configuration overrides (apps, warning apps, etc.)
  * `assay/shutdown` - Cleanly stops the daemon

  ## Usage

      mix assay.daemon

  The daemon reads JSON-RPC requests from stdin and writes responses to stdout.
  See `Assay.Daemon` for implementation details.
  """
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
