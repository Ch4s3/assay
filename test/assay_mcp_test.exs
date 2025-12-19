defmodule Assay.MCPTest do
  use ExUnit.Case, async: true

  alias Assay.{MCP, Daemon}

  defmodule FakeDaemon do
    def new(opts), do: opts[:state] || Daemon.new(opts)

    def handle_rpc(request, state) do
      case request["method"] do
        "assay/analyze" ->
          reply = %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{"status" => "ok", "warnings" => []}
          }

          {reply, state, :continue}
      end
    end
  end

  setup do
    daemon =
      FakeDaemon.new(
        config: Assay.Config.from_mix_project(),
        runner: Assay.DaemonTest.FakeRunner
      )

    %{state: %MCP{daemon: daemon}}
  end

  test "initialize handshake", %{state: state} do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"clientInfo" => %{"name" => "test"}}
    }

    {reply, new_state, :continue} = MCP.handle_rpc(request, state)

    assert reply["result"]["protocolVersion"] == "2024-11-05"
    assert new_state.initialized?
  end

  test "tools/list exposes analyzer tool", %{state: state} do
    {_, state, _} =
      MCP.handle_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, state)

    {reply, _state, :continue} =
      MCP.handle_rpc(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, state)

    tool = hd(reply["result"]["tools"])
    assert tool["name"] == "assay.analyze"
  end

  test "tools/call invokes daemon analyze", %{state: state} do
    {_, state, _} =
      MCP.handle_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, state)

    params = %{"name" => "assay.analyze", "arguments" => %{"formats" => ["text"]}}
    request = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => params}

    {reply, _state, :continue} = MCP.handle_rpc(request, state)

    assert %{"content" => [%{"type" => "json", "json" => result}]} = reply["result"]
    assert result["status"] in ["ok", "warnings"]
  end
end
