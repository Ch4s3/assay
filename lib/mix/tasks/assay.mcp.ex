defmodule Mix.Tasks.Assay.Mcp do
  @moduledoc false

  use Mix.Task

  @shortdoc "Run Assay as an MCP (Model Context Protocol) server"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")
    Assay.MCP.serve()
  end
end
