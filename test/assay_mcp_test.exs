defmodule Assay.MCPTest do
  use ExUnit.Case, async: false

  alias Assay.{Config, Daemon, MCP}

  defmodule StubRunner do
    def analyze(_config, _opts) do
      %{status: :ok, warnings: [], ignored: [], ignore_path: nil}
    end
  end

  defmodule ErrorRunner do
    def analyze(_config, _opts) do
      raise "boom"
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "assay-mcp-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    config = Config.from_mix_project(project_root: root)
    daemon = Daemon.new(config: config, runner: StubRunner)

    on_exit(fn -> File.rm_rf(root) end)

    %{daemon: daemon}
  end

  test "tools/list requires initialization", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)
    {reply, _state, :continue} = MCP.handle_rpc(%{"id" => 1, "method" => "tools/list"}, state)

    assert reply["error"]["code"] == -32_602
  end

  test "initialize stores client info", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)

    {reply, new_state, :continue} =
      MCP.handle_rpc(
        %{
          "id" => 2,
          "method" => "initialize",
          "params" => %{"clientInfo" => %{"name" => "test-client"}}
        },
        state
      )

    assert reply["result"]["protocolVersion"] == "2024-11-05"
    assert new_state.initialized?
    assert new_state.client_info == %{"name" => "test-client"}
  end

  test "initialize rejects repeated calls", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)
    {_reply, initialized, :continue} = MCP.handle_rpc(%{"id" => 10, "method" => "initialize"}, state)

    {reply, _state, :continue} =
      MCP.handle_rpc(%{"id" => 11, "method" => "initialize"}, initialized)

    assert reply["error"]["code"] == -32_602
  end

  test "tools/call delegates to the daemon and echoes toolCallId", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)
    {_reply, initialized, :continue} = MCP.handle_rpc(%{"id" => 3, "method" => "initialize"}, state)

    {reply, _state, :continue} =
      MCP.handle_rpc(
        %{
          "id" => 4,
          "method" => "tools/call",
          "params" => %{
            "name" => "assay.analyze",
            "toolCallId" => "call-1",
            "arguments" => %{"formats" => ["json"]}
          }
        },
        initialized
      )

    assert reply["result"]["toolCallId"] == "call-1"
    assert %{"content" => [%{"type" => "json"}]} = reply["result"]
  end

  test "tools/call surfaces daemon errors", %{daemon: daemon} do
    error_daemon = %{daemon | runner: ErrorRunner}
    state = MCP.new(daemon: error_daemon, halt_on_stop?: false)
    {_reply, initialized, :continue} = MCP.handle_rpc(%{"id" => 8, "method" => "initialize"}, state)

    {reply, _state, :continue} =
      MCP.handle_rpc(
        %{
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "assay.analyze"}
        },
        initialized
      )

    assert reply["error"]["code"] == -32_000
    assert reply["error"]["message"] =~ "boom"
  end

  test "tools/call rejects unknown tools", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)
    {_reply, initialized, :continue} = MCP.handle_rpc(%{"id" => 5, "method" => "initialize"}, state)

    {reply, _state, :continue} =
      MCP.handle_rpc(
        %{"id" => 6, "method" => "tools/call", "params" => %{"name" => "unknown"}},
        initialized
      )

    assert reply["error"]["code"] == -32_601
  end

  test "notifications/initialized returns no reply", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)
    {reply, _state, :continue} = MCP.handle_rpc(%{"method" => "notifications/initialized"}, state)

    assert reply == nil
  end

  test "exit returns stop action", %{daemon: daemon} do
    state = MCP.new(daemon: daemon, halt_on_stop?: false)
    {reply, _state, :stop} = MCP.handle_rpc(%{"id" => 7, "method" => "exit"}, state)

    assert reply["result"]["status"] == "shutting_down"
  end
end
