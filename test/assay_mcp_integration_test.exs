defmodule Assay.MCPIntegrationTest do
  @moduledoc """
  Integration tests for the MCP server that test the full stdio-based communication.

  These tests simulate a real MCP client communicating with the server over stdio.
  """
  use ExUnit.Case, async: false

  alias Assay.{Daemon, MCP}

  @moduletag :integration

  # Define a simple fake runner for testing
  defmodule FakeRunner do
    def analyze(_config, _opts) do
      %{
        status: :ok,
        warnings: [],
        ignored: [],
        ignore_path: nil,
        options: []
      }
    end
  end

  setup do
    config = Assay.Config.from_mix_project()
    daemon = Daemon.new(config: config, runner: FakeRunner)
    state = MCP.new(daemon: daemon)
    %{state: state}
  end

  # Helper to test the MCP server by simulating stdio communication.
  # This spawns a process that simulates the server's stdio loop and allows
  # you to send JSON-RPC messages and receive responses.
  defp test_mcp_server(state, messages) do
    # Create a process that will simulate the server
    parent = self()

    server_pid =
      spawn(fn ->
        # Redirect stdio to our test process
        # We'll use message passing to simulate stdio
        server_loop(state, parent)
      end)

    # Send messages and collect responses
    responses =
      Enum.map(messages, fn message ->
        json = JSON.encode!(message) <> "\n"
        send(server_pid, {:stdin, json})

        # Notifications don't return responses
        if Map.has_key?(message, "id") do
          receive do
            {:stdout, response_json} ->
              case JSON.decode(response_json) do
                {:ok, response} -> response
                {:error, _} -> %{"raw" => response_json}
              end
          after
            1000 -> %{"error" => %{"message" => "timeout"}}
          end
        else
          # For notifications, wait a bit to ensure processing
          Process.sleep(10)
          nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    # Clean up
    send(server_pid, :stop)
    Process.sleep(10)
    responses
  end

  defp server_loop(state, parent) do
    receive do
      {:stdin, line} ->
        case process_input(line, state, parent) do
          {:continue, next_state} -> server_loop(next_state, parent)
          :stop -> :ok
        end

      :stop ->
        :ok
    end
  end

  defp process_input(line, state, parent) do
    trimmed = String.trim_trailing(line, "\n")

    if trimmed == "" do
      {:continue, state}
    else
      case JSON.decode(trimmed) do
        {:ok, message} ->
          {reply, new_state, action} = MCP.handle_rpc(message, state)
          send_reply(reply, parent)
          handle_action(action, new_state)

        {:error, _} ->
          send_invalid_json(parent)
          {:continue, state}
      end
    end
  end

  defp send_reply(nil, _parent), do: :ok

  defp send_reply(payload, parent) do
    response_json = JSON.encode!(payload) <> "\n"
    send(parent, {:stdout, response_json})
  end

  defp send_invalid_json(parent) do
    reply = %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32_700, "message" => "Invalid JSON"}
    }

    send(parent, {:stdout, JSON.encode!(reply) <> "\n"})
  end

  defp handle_action(:continue, new_state), do: {:continue, new_state}
  defp handle_action(:stop, _state), do: :stop

  test "full MCP handshake and tool call", %{state: state} do
    messages = [
      # Initialize
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "test-client"}}
      },
      # Notification (no response expected)
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      },
      # List tools
      %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list"
      },
      # Call tool
      %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "assay.analyze",
          "arguments" => %{"formats" => ["text"]}
        }
      }
    ]

    [init_response, tools_response, tool_response] =
      test_mcp_server(state, messages)

    # Verify initialize response
    assert init_response["result"]["protocolVersion"] == "2024-11-05"
    assert init_response["id"] == 1

    # Verify tools/list response
    assert tools_response["result"]["tools"] |> length() == 1
    tool = hd(tools_response["result"]["tools"])
    assert tool["name"] == "assay.analyze"

    # Verify tool call response
    assert Map.has_key?(tool_response, "result")
    assert Map.has_key?(tool_response["result"], "content")
    content_list = tool_response["result"]["content"]
    assert is_list(content_list)
    assert length(content_list) == 1
    content = hd(content_list)
    assert content["type"] == "json"
    assert content["json"]["status"] in ["ok", "warnings"]
  end

  test "handles invalid JSON gracefully", %{state: state} do
    # Send invalid JSON directly to the server loop
    parent = self()

    server_pid =
      spawn(fn ->
        server_loop(state, parent)
      end)

    send(server_pid, {:stdin, "invalid json\n"})

    response =
      receive do
        {:stdout, response_json} ->
          case JSON.decode(response_json) do
            {:ok, response} -> response
            {:error, _} -> %{"raw" => response_json}
          end
      after
        1000 -> %{"error" => %{"message" => "timeout"}}
      end

    send(server_pid, :stop)

    assert response["error"]["code"] == -32_700
    assert response["error"]["message"] == "Invalid JSON"
  end

  test "handles shutdown request", %{state: state} do
    messages = [
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "shutdown"
      }
    ]

    [response] = test_mcp_server(state, messages)

    assert response["result"]["status"] == "shutting_down"
    assert response["id"] == 1
  end

  test "handles unknown method", %{state: state} do
    messages = [
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "unknown/method"
      }
    ]

    [response] = test_mcp_server(state, messages)

    assert response["error"]["code"] == -32_601
    assert response["id"] == 1
  end

  test "serve consumes stdio stream and writes framed responses", %{state: state} do
    messages = [
      %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"},
      %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
    ]

    input =
      messages
      |> Enum.map_join("\n", fn msg -> JSON.encode!(msg) end)

    {:ok, io} = StringIO.open(input)

    previous_shell = Mix.shell()

    task =
      Task.async(fn ->
        Process.group_leader(self(), io)
        MCP.serve(daemon: state.daemon)
      end)

    assert :ok == Task.await(task, 1000)
    Mix.shell(previous_shell)

    {_remaining_input, output} = StringIO.contents(io)

    assert output =~ "Content-Length:"
    assert output =~ "\"protocolVersion\""
    assert output =~ "\"tools\""
  end
end
