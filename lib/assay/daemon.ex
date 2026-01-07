defmodule Assay.Daemon do
  @moduledoc """
  JSON-RPC daemon that exposes incremental Dialyzer runs to tooling (e.g. MCP).

  The daemon speaks line-delimited JSON-RPC over stdio. Each request must be a
  single JSON object terminated by a newline. Responses are emitted in the same
  format. Only a handful of methods are implemented:

    * `assay/analyze`   — triggers an incremental run and returns diagnostics
    * `assay/getStatus` — reports the daemon status and last run result
    * `assay/getConfig` — returns the current config (including overrides)
    * `assay/setConfig` — applies config overrides (apps, warning apps, etc)
    * `assay/shutdown`  — cleanly stops the daemon
  """

  alias Assay.{Config, Formatter, Runner}

  @jsonrpc "2.0"
  @allowed_overrides ~w(apps warning_apps cache_dir plt_path ignore_file)a

  defstruct base_config: nil,
            config: nil,
            overrides: %{},
            status: :idle,
            last_result: nil,
            runner: Assay.Runner

  @type t :: %__MODULE__{
          base_config: Config.t(),
          config: Config.t(),
          overrides: map(),
          status: :idle | :running,
          last_result: map() | nil,
          runner: module()
        }

  @doc """
  Starts the daemon and blocks, reading JSON-RPC requests from stdio.
  """
  @spec serve(keyword()) :: no_return()
  def serve(opts \\ []) do
    Mix.shell(Mix.Shell.Quiet)
    state = new(opts)
    stream(state)
  end

  @doc """
  Initializes daemon state. Accepts `:config` and `:runner` overrides for tests.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_config =
      opts[:config] ||
        Config.from_mix_project(
          opts
          |> Keyword.take([:project_root, :cache_dir, :plt_path])
        )

    runner = Keyword.get(opts, :runner, Runner)

    %__MODULE__{
      base_config: base_config,
      config: base_config,
      runner: runner
    }
  end

  @doc """
  Handles a decoded JSON-RPC request map and returns `{reply | nil, state, action}`.

  Useful for tests; `action` is either `:continue` or `:stop`.

  ## Examples

      # Analyze request
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "assay/analyze",
        "params" => %{"formats" => ["json"]}
      }
      state = Assay.Daemon.new()
      {reply, new_state, action} = Assay.Daemon.handle_rpc(request, state)
      # reply contains JSON-RPC response with diagnostics
      # action is :continue

      # Get status request
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "assay/getStatus"
      }
      {reply, new_state, action} = Assay.Daemon.handle_rpc(request, state)
      # reply contains status information
      # action is :continue

      # Shutdown request
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "assay/shutdown"
      }
      {reply, new_state, action} = Assay.Daemon.handle_rpc(request, state)
      # action is :stop
  """
  @spec handle_rpc(map(), t()) :: {map() | nil, t(), :continue | :stop}
  def handle_rpc(%{"method" => method} = request, %__MODULE__{} = state) do
    id = Map.get(request, "id")
    params = normalize_params(Map.get(request, "params", %{}))

    case dispatch(method, params, state) do
      {:ok, result, new_state} ->
        reply = if id, do: jsonrpc_reply(id, result), else: nil
        {reply, new_state, :continue}

      {:error, code, message, data, new_state} ->
        reply = if id, do: jsonrpc_error(id, code, message, data), else: nil
        {reply, new_state, :continue}

      {:shutdown, result, new_state} ->
        reply = if id, do: jsonrpc_reply(id, result), else: nil
        {reply, new_state, :stop}
    end
  end

  def handle_rpc(_other, state), do: {nil, state, :continue}

  defp dispatch("assay/analyze", params, %__MODULE__{} = state) do
    formats = Map.get(params, "formats", ["json"])

    running = %{state | status: :running}

    analysis =
      running.runner.analyze(running.config, quiet: true, formats: normalize_formats(formats))

    payload = %{
      "status" => Atom.to_string(analysis.status),
      "warnings" =>
        Enum.map(
          analysis.warnings,
          &Formatter.warning_payload(&1, running.config.project_root)
        ),
      "ignored" => length(analysis.ignored),
      "ignore_file" => display_ignore_path(analysis.ignore_path, running.config.project_root),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    finished = %{running | status: :idle, last_result: payload}

    {:ok, payload, finished}
  rescue
    error ->
      {:error, -32_000, Exception.message(error), %{"type" => inspect(error.__struct__)}, state}
  end

  defp dispatch("assay/getStatus", _params, %__MODULE__{} = state) do
    payload = %{
      "state" => Atom.to_string(state.status),
      "last_result" => state.last_result
    }

    {:ok, payload, state}
  end

  defp dispatch("assay/getConfig", _params, %__MODULE__{} = state) do
    payload = %{
      "config" => config_payload(state.config),
      "overrides" => overrides_payload(state.overrides)
    }

    {:ok, payload, state}
  end

  defp dispatch("assay/setConfig", %{"config" => override_map}, %__MODULE__{} = state)
       when is_map(override_map) do
    overrides = merge_overrides(state.overrides, override_map)
    config = apply_overrides(state.base_config, overrides)
    next_state = %{state | overrides: overrides, config: config}
    {:ok, %{"config" => config_payload(config)}, next_state}
  rescue
    error in [ArgumentError] ->
      {:error, -32_602, Exception.message(error), nil, state}
  end

  defp dispatch("assay/shutdown", _params, %__MODULE__{} = state) do
    {:shutdown, %{"status" => "shutting_down"}, state}
  end

  defp dispatch(method, _params, %__MODULE__{} = state) do
    {:error, -32_601, "Unknown method #{method}", nil, state}
  end

  defp stream(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data ->
        trimmed = String.trim(trailing_newlines(data))

        if trimmed == "" do
          stream(state)
        else
          {reply, new_state, action} = process_line(trimmed, state)
          maybe_write(reply)
          handle_action(action, new_state)
        end
    end
  end

  defp handle_action(:continue, state), do: stream(state)
  defp handle_action(:stop, _state), do: System.halt(0)

  defp trailing_newlines(data) do
    String.trim_trailing(data, "\n")
  end

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

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_), do: %{}

  defp normalize_formats(list) when is_list(list) do
    Enum.map(list, fn
      format when is_binary(format) ->
        String.to_atom(format)

      format when is_atom(format) ->
        format

      _ ->
        :text
    end)
  end

  defp normalize_formats(_), do: [:text]

  defp config_payload(%Config{} = config) do
    %{
      "apps" => Enum.map(config.apps, &format_app_value/1),
      "warning_apps" => Enum.map(config.warning_apps, &format_app_value/1),
      "cache_dir" => config.cache_dir,
      "plt_path" => config.plt_path,
      "ignore_file" => config.ignore_file,
      "project_root" => config.project_root
    }
  end

  defp overrides_payload(overrides) when map_size(overrides) == 0, do: %{}

  defp overrides_payload(overrides) do
    Enum.into(overrides, %{}, fn {key, value} ->
      {Atom.to_string(key), encode_override_value(value)}
    end)
  end

  defp encode_override_value(list) when is_list(list) do
    Enum.map(list, &format_app_value/1)
  end

  defp encode_override_value(other), do: other

  defp format_app_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_app_value(value) when is_binary(value), do: value
  defp format_app_value(value) when is_list(value), do: List.to_string(value)
  defp format_app_value(other), do: inspect(other)

  defp merge_overrides(current, incoming) do
    Enum.reduce(incoming, current, fn {key, value}, acc ->
      atom_key = normalize_override_key(key)
      Map.put(acc, atom_key, normalize_override_value(atom_key, value))
    end)
  end

  defp normalize_override_key(key) when is_atom(key) and key in @allowed_overrides, do: key

  defp normalize_override_key(key) when is_atom(key) do
    raise ArgumentError, "Unsupported override key: #{inspect(key)}"
  end

  defp normalize_override_key(key) when is_binary(key) do
    case Enum.find(@allowed_overrides, fn allowed -> Atom.to_string(allowed) == key end) do
      nil -> raise ArgumentError, "Unsupported override key: #{key}"
      atom -> atom
    end
  end

  defp normalize_override_key(other) do
    raise ArgumentError, "Unsupported override key: #{inspect(other)}"
  end

  defp normalize_override_value(key, value) when key in [:apps, :warning_apps] do
    value
    |> List.wrap()
    |> Enum.map(&to_existing_or_new_atom/1)
  end

  defp normalize_override_value(_key, value) when is_binary(value), do: value
  defp normalize_override_value(_key, value) when is_list(value), do: List.to_string(value)
  defp normalize_override_value(_key, nil), do: nil
  defp normalize_override_value(_key, other), do: to_string(other)

  defp to_existing_or_new_atom(value) when is_atom(value), do: value

  defp to_existing_or_new_atom(value) when is_binary(value) do
    String.to_atom(value)
  end

  defp to_existing_or_new_atom(value) when is_list(value) do
    value |> List.to_string() |> String.to_atom()
  end

  defp apply_overrides(config, overrides) do
    Enum.reduce(overrides, config, fn
      {:apps, apps}, acc -> %{acc | apps: apps}
      {:warning_apps, apps}, acc -> %{acc | warning_apps: apps}
      {:cache_dir, dir}, acc -> %{acc | cache_dir: dir}
      {:plt_path, path}, acc -> %{acc | plt_path: path}
      {:ignore_file, file}, acc -> %{acc | ignore_file: file}
      _other, acc -> acc
    end)
  end

  defp display_ignore_path(nil, _root), do: nil

  defp display_ignore_path(path, root) do
    case Path.relative_to(path, root) do
      relative when relative != path -> relative
      _ -> path
    end
  rescue
    _ -> path
  end

  defp jsonrpc_reply(id, result) do
    %{
      "jsonrpc" => @jsonrpc,
      "id" => id,
      "result" => result
    }
  end

  defp jsonrpc_error(nil, code, message, data) do
    %{
      "jsonrpc" => @jsonrpc,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end

  defp jsonrpc_error(id, code, message, data) do
    %{
      "jsonrpc" => @jsonrpc,
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end

  defp maybe_write(nil), do: :ok

  defp maybe_write(payload) do
    payload
    |> JSON.encode!()
    |> Kernel.<>("\n")
    |> IO.binwrite()
  end
end
