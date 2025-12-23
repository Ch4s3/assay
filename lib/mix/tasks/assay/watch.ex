defmodule Mix.Tasks.Assay.Watch do
  @moduledoc false
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
