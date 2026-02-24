defmodule Mix.Tasks.Assay.Mcp do
  @moduledoc """
  Run Assay as an MCP (Model Context Protocol) server over stdio.

  The server implements the Model Context Protocol and exposes a single tool:
  `assay.analyze`, which runs incremental Dialyzer and returns structured diagnostics.

  MCP clients (e.g., IDE agents) can:
  * `initialize` - Initialize the MCP connection
  * `tools/list` - List available tools
  * `tools/call` - Invoke the `assay.analyze` tool

  Requests/responses use the standard MCP/LSP framing: each JSON payload must be
  prefixed with `Content-Length: <bytes>\\r\\n\\r\\n`.

  ## Usage

      mix assay.mcp

  The server reads MCP requests from stdin and writes responses to stdout.
  See `Assay.MCP` for implementation details.
  """
  use Mix.Task

  @shortdoc "Run Assay as an MCP (Model Context Protocol) server"

  @impl true
  def run(argv) do
    reject_no_compile!(argv)
    Mix.Task.run("app.start")
    mcp_module().serve()
  end

  defp reject_no_compile!(args) do
    if "--no-compile" in args do
      Mix.raise(
        "--no-compile is not supported with mix assay.mcp " <>
          "(the MCP server must compile on each analysis)"
      )
    end
  end

  defp mcp_module do
    Application.get_env(:assay, :mcp_module, Assay.MCP)
  end
end
