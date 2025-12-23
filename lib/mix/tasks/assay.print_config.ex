defmodule Mix.Tasks.Assay.PrintConfig do
  @moduledoc false
  use Mix.Task

  @shortdoc "Print the effective Dialyzer configuration"

  @impl true
  def run(args) do
    Mix.Task.run("assay", ["--print-config" | args])
  end
end
