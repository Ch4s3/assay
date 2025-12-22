defmodule Assay.MCPTest do
  use ExUnit.Case, async: true

  alias Assay.{MCP, Daemon}
  alias Assay.DaemonTest.FakeRunner

  defmodule CaptureRunner do
    def analyze(config, opts) do
      send(self(), {:daemon_request, opts})
      FakeRunner.analyze(config, opts)
    end
  end

  defmodule ErrorRunner do
    def analyze(_config, _opts), do: raise("daemon failure")
  end

  setup do
    config = Assay.Config.from_mix_project()
    daemon = Daemon.new(config: config, runner: FakeRunner)
    %{state: %MCP{daemon: daemon}, config: config}
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

  test "tools/call preserves toolCallId and forwards arguments", %{config: config} do
    state = %MCP{daemon: Daemon.new(config: config, runner: CaptureRunner)}

    {_, state, _} =
      MCP.handle_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, state)

    params = %{"name" => "assay.analyze", "arguments" => %{"formats" => ["text"]}, "toolCallId" => "abc123"}
    request = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => params}

    {reply, _state, :continue} = MCP.handle_rpc(request, state)

    assert reply["result"]["toolCallId"] == "abc123"
    assert_receive {:daemon_request, opts}
    assert opts[:formats] == [:text]
  end

  test "tools/call errors when daemon fails", %{config: config} do
    state = %MCP{daemon: Daemon.new(config: config, runner: ErrorRunner)}

    {_, state, _} =
      MCP.handle_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, state)

    params = %{"name" => "assay.analyze"}
    request = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/call", "params" => params}

    {reply, _state, :continue} = MCP.handle_rpc(request, state)
    assert reply["error"]["code"] == -32_000
  end

  test "tools/call rejects unknown tools", %{state: state} do
    {_, state, _} =
      MCP.handle_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, state)

    params = %{"name" => "unknown.tool"}
    request = %{"jsonrpc" => "2.0", "id" => 4, "method" => "tools/call", "params" => params}

    {reply, _state, :continue} = MCP.handle_rpc(request, state)
    assert reply["error"]["code"] == -32_601
  end

  test "shutdown requests stop the loop", %{state: state} do
    shutdown_request = %{"jsonrpc" => "2.0", "id" => 5, "method" => "shutdown"}
    {reply, _state, action} = MCP.handle_rpc(shutdown_request, state)

    assert reply["result"]["status"] == "shutting_down"
    assert action == :stop
  end

  test "notifications are acknowledged without replies", %{state: state} do
    request = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    {reply, _state, :continue} = MCP.handle_rpc(request, state)
    assert reply == nil
  end
end
