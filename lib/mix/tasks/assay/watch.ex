defmodule Mix.Tasks.Assay.Watch do
  @moduledoc """
  Watch project files and rerun incremental Dialyzer on change.

  This task watches common project directories (`lib`, `apps`, `config`, `test`)
  and automatically re-runs Dialyzer when files change. Changes are debounced
  to avoid excessive runs, and in-flight analysis tasks are cancelled when new
  changes are detected.

  The watcher automatically ignores build artifacts (`_build/`, `deps/`, `.git/`).

  Press Ctrl+C to stop watching.

  ## Usage

      mix assay.watch
  """
  use Mix.Task

  @shortdoc "Watch project files and rerun incremental Dialyzer on change"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    # Ensure file_system application is started
    Application.ensure_all_started(:file_system)
    watch_module().run()
  end

  defp watch_module do
    Application.get_env(:assay, :watch_module, Assay.Watch)
  end
end
