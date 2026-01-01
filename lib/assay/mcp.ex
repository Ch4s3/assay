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
            },
            halt_on_stop?: true

  @type t :: %__MODULE__{
          daemon: Daemon.t(),
          initialized?: boolean(),
          client_info: map(),
          server_info: map(),
          halt_on_stop?: boolean()
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
      daemon: daemon,
      halt_on_stop?: Keyword.get(opts, :halt_on_stop?, true)
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

  defp dispatch("initialize", _params, %__MODULE__{initialized?: true} = state) do
    {:error, -32_602, "Server already initialized", nil, state}
  end

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
    ensure_initialized(state, fn ->
      {:ok, %{"tools" => [tool_spec()]}, state}
    end)
  end

  defp dispatch("tools/call", params, %__MODULE__{} = state) do
    ensure_initialized(state, fn ->
      case Map.get(params, "name") do
        @tool_name ->
          handle_tool_call(params, state)

        other ->
          {:error, -32_601, "Unknown tool #{inspect(other)}", nil, state}
      end
    end)
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
    case read_message() do
      {:ok, ""} ->
        loop(state)

      {:ok, data} ->
        trimmed = String.trim(data)

        if trimmed == "" do
          loop(state)
        else
          {reply, new_state, action} = process_line(trimmed, state)
          maybe_write(reply)
          handle_action(action, new_state)
        end

      :eof ->
        :ok

      {:error, reason} ->
        maybe_write(
          jsonrpc_error(nil, -32_700, "Invalid MCP frame", %{"reason" => inspect(reason)})
        )

        loop(state)
    end
  end

  defp handle_action(:continue, state), do: loop(state)

  defp handle_action(:stop, %__MODULE__{halt_on_stop?: true}), do: System.halt(0)
  defp handle_action(:stop, %__MODULE__{}), do: :ok

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
    json = JSON.encode!(payload)
    packet = "Content-Length: #{byte_size(json)}\r\n\r\n" <> json
    IO.binwrite(packet)
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

  defp ensure_initialized(%__MODULE__{initialized?: true}, fun) do
    fun.()
  end

  defp ensure_initialized(state, _fun) do
    {:error, -32_602, "Server not initialized", nil, state}
  end

  defp read_message do
    case IO.binread(:stdio, :line) do
      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}

      data ->
        trimmed = trim_line(data)

        cond do
          trimmed == "" ->
            read_message()

          header_line?(trimmed) ->
            read_framed_message(%{}, data)

          true ->
            {:ok, trimmed}
        end
    end
  end

  defp read_framed_message(headers, first_line) do
    with {:ok, headers} <- read_headers(headers, first_line),
         {:ok, length} <- fetch_content_length(headers),
         {:ok, _body} = result <- handle_body(IO.binread(:stdio, length), length) do
      result
    end
  end

  defp read_headers(headers, line) do
    trimmed = trim_line(line)

    if trimmed == "" do
      {:ok, headers}
    else
      with {:ok, updated} <- parse_header_line(trimmed, headers),
           next <- IO.binread(:stdio, :line) do
        case next do
          :eof -> {:error, :unexpected_eof}
          {:error, reason} -> {:error, reason}
          data -> read_headers(updated, data)
        end
      end
    end
  end

  defp parse_header_line(line, headers) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        key = String.downcase(String.trim(name))
        {:ok, Map.put(headers, key, String.trim(value))}

      _ ->
        {:error, :invalid_header}
    end
  end

  defp fetch_content_length(headers) do
    case Map.fetch(headers, "content-length") do
      {:ok, value} ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> {:ok, int}
          _ -> {:error, :invalid_content_length}
        end

      :error ->
        {:error, :missing_content_length}
    end
  end

  defp handle_body({:error, reason}, _expected), do: {:error, reason}
  defp handle_body(:eof, _expected), do: {:error, :unexpected_eof}

  defp handle_body(data, expected) when is_binary(data) do
    if byte_size(data) == expected do
      {:ok, data}
    else
      {:error, :short_body}
    end
  end

  defp header_line?(line) do
    String.downcase(line) |> String.starts_with?("content-length:")
  end

  defp trim_line(line) do
    line
    |> to_string()
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
