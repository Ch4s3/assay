defmodule Assay.MCPSTDIOTest do
  use ExUnit.Case, async: true

  alias Assay.{MCP, Daemon}
  alias Assay.TestSupport.IOProxy

  defmodule StubRunner do
    def analyze(_config, opts) do
      send(self(), {:runner_opts, opts})
      %{status: :ok, warnings: [], ignored: [], ignore_path: nil, options: []}
    end
  end

  setup do
    config = Assay.Config.from_mix_project(project_root: temp_dir())
    daemon = Daemon.new(config: config, runner: StubRunner)

    input = IOProxy.start_link()
    output = IOProxy.start_link()

    %{state: MCP.new(daemon: daemon), input: input, output: output}
  end

  test "process_line handles JSON frames", %{state: state} do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    request = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
    {reply, new_state, :continue} = MCP.handle_rpc(JSON.decode!(request), state)
    assert reply["result"]["protocolVersion"] == "2024-11-05"
    assert new_state.initialized?
  end

  defp temp_dir do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "assay-mcp-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(path)
    path
  end
end
