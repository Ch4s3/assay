defmodule Assay.MCP do
  @moduledoc """
  Minimal Model Context Protocol (MCP) server built on top of the Assay daemon.

  The server speaks JSON-RPC over stdio and exposes a single tool:

    * `assay.analyze` — runs incremental Dialyzer and returns structured diagnostics.

  MCP clients (e.g. IDE agents) can `initialize`, list tools, and invoke the tool
  using `tools/call`.
  """

  alias Assay.Daemon

  @protocol_version "2024-11-05"
  @tool_name "assay.analyze"

  defstruct daemon: nil,
            initialized?: false,
            client_info: %{},
            server_info: %{
              "name" => "assay",
              "version" => Mix.Project.config()[:version]
            }

  @type t :: %__MODULE__{
          daemon: Daemon.t(),
          initialized?: boolean(),
          client_info: map(),
          server_info: map()
        }

  @doc """
  Starts the MCP server and blocks, reading JSON-RPC over stdio.
  """
  @spec serve(keyword()) :: no_return()
  def serve(opts \\ []) do
    Mix.shell(Mix.Shell.Quiet)
    state = new(opts)
    loop(state)
  end

  @doc """
  Initializes MCP state. Accepts `:daemon` (for tests) or `:config` overrides.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    daemon =
      opts[:daemon] ||
        Daemon.new(opts)

    %__MODULE__{
      daemon: daemon
    }
  end

  @doc """
  Handles a JSON-RPC request map and returns `{reply | nil, state, action}`.

  `action` is either `:continue` or `:stop`. Primarily used in tests.
  """
  @spec handle_rpc(map(), t()) :: {map() | nil, t(), :continue | :stop}
  def handle_rpc(%{"method" => method} = request, %__MODULE__{} = state) do
    id = Map.get(request, "id")
    params = normalize_params(Map.get(request, "params", %{}))

    case dispatch(method, params, state) do
      {:ok, result, new_state} ->
        reply = if id, do: jsonrpc_reply(id, result), else: nil
        {reply, new_state, :continue}

      {:notify, new_state} ->
        {nil, new_state, :continue}

      {:error, code, message, data, new_state} ->
        reply = if id, do: jsonrpc_error(id, code, message, data), else: nil
        {reply, new_state, :continue}

      {:shutdown, result, new_state} ->
        reply = if id, do: jsonrpc_reply(id, result), else: nil
        {reply, new_state, :stop}
    end
  end

  def handle_rpc(_other, state), do: {nil, state, :continue}

  defp dispatch("initialize", params, %__MODULE__{} = state) do
    capabilities = %{
      "tools" => %{"listChanged" => true}
    }

    reply = %{
      "protocolVersion" => @protocol_version,
      "serverInfo" => state.server_info,
      "capabilities" => capabilities
    }

    new_state = %{state | initialized?: true, client_info: Map.get(params, "clientInfo", %{})}
    {:ok, reply, new_state}
  end

  defp dispatch("notifications/initialized", _params, %__MODULE__{} = state) do
    {:notify, state}
  end

  defp dispatch("tools/list", _params, %__MODULE__{} = state) do
    {:ok, %{"tools" => [tool_spec()]}, state}
  end

  defp dispatch("tools/call", params, %__MODULE__{} = state) do
    case Map.get(params, "name") do
      @tool_name ->
        handle_tool_call(params, state)

      other ->
        {:error, -32_601, "Unknown tool #{inspect(other)}", nil, state}
    end
  end

  defp dispatch("shutdown", _params, %__MODULE__{} = state) do
    {:shutdown, %{"status" => "shutting_down"}, state}
  end

  defp dispatch("exit", _params, %__MODULE__{} = state) do
    {:shutdown, %{"status" => "shutting_down"}, state}
  end

  defp dispatch(method, _params, %__MODULE__{} = state) do
    {:error, -32_601, "Unknown method #{method}", nil, state}
  end

  defp handle_tool_call(params, %__MODULE__{} = state) do
    arguments = Map.get(params, "arguments", %{})

    request = %{
      "jsonrpc" => "2.0",
      "id" => "__mcp__",
      "method" => "assay/analyze",
      "params" => arguments
    }

    {reply, daemon_state, _action} = Daemon.handle_rpc(request, state.daemon)

    case reply do
      %{"error" => error} ->
        {:error, error["code"], error["message"], error["data"], %{state | daemon: daemon_state}}

      %{"result" => result} ->
        content = [
          %{
            "type" => "json",
            "json" => result
          }
        ]

        tool_response =
          %{"content" => content}
          |> maybe_put_tool_call_id(Map.get(params, "toolCallId"))

        {:ok, tool_response, %{state | daemon: daemon_state}}
    end
  rescue
    error ->
      {:error, -32_000, Exception.message(error), %{"type" => inspect(error.__struct__)}, state}
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _} -> :ok
      data -> process_input(data, state)
    end
  end

  defp process_input(data, state) do
    trimmed = String.trim_trailing(data || "", "\n")

    if trimmed == "" do
      loop(state)
    else
      {reply, new_state, action} = process_line(trimmed, state)
      maybe_write(reply)
      handle_action(action, new_state)
    end
  end

  defp handle_action(:continue, state), do: loop(state)
  defp handle_action(:stop, _state), do: System.halt(0)

  defp process_line(line, state) do
    case JSON.decode(line) do
      {:ok, message} ->
        handle_rpc(message, state)

      {:error, _} ->
        reply = jsonrpc_error(nil, -32_700, "Invalid JSON", %{"raw" => line})
        maybe_write(reply)
        {nil, state, :continue}
    end
  end

  defp maybe_write(nil), do: :ok

  defp maybe_write(payload) do
    payload
    |> JSON.encode!()
    |> Kernel.<>("\n")
    |> IO.binwrite()
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_), do: %{}

  defp tool_spec do
    %{
      "name" => @tool_name,
      "description" => "Run incremental Dialyzer using Assay",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "formats" => %{
            "type" => "array",
            "description" => "Optional output formats (text, github, sarif, lsp, ndjson, llm)",
            "items" => %{"type" => "string"}
          }
        },
        "required" => []
      }
    }
  end

  defp maybe_put_tool_call_id(map, nil), do: map
  defp maybe_put_tool_call_id(map, id), do: Map.put(map, "toolCallId", id)

  defp jsonrpc_reply(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  defp jsonrpc_error(nil, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end

  defp jsonrpc_error(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end
end
