# Ensure :tools application is loaded for coverage
# This helps the cover tool find its stylesheet
try do
  :code.ensure_loaded(:tools)
  case :code.priv_dir(:tools) do
    {:error, _} ->
      # Tools application not found - coverage HTML reports may fail
      # but coverage data collection should still work
      :ok
    _ ->
      # Tools found, try to start it if it's an application
      Application.ensure_all_started(:tools)
  end
rescue
  _ -> :ok
end

ExUnit.start()

defmodule Assay.TestSupport.ConfigStub do
  alias Assay.Config

  def from_mix_project(opts) do
    send(self(), {:config_opts, opts})
    root = Keyword.get(opts, :project_root, "/tmp/assay-test")
    apps = Keyword.get(opts, :apps, [:stub])
    warning_apps = Keyword.get(opts, :warning_apps, apps)
    cache_dir = Path.join(root, "_build/assay")
    plt_filename = Config.plt_filename()

    %Config{
      apps: apps,
      warning_apps: warning_apps,
      project_root: root,
      cache_dir: cache_dir,
      plt_path: Path.join(cache_dir, plt_filename),
      build_lib_path: Path.join(root, "_build/dev/lib"),
      elixir_lib_path: Path.join(root, ".elixir"),
      ignore_file: Path.join(root, "dialyzer_ignore.exs"),
      warnings: Keyword.get(opts, :warnings, []),
      app_sources: Keyword.get(opts, :app_sources, []),
      warning_app_sources: Keyword.get(opts, :warning_app_sources, []),
      dialyzer_flags: Keyword.get(opts, :dialyzer_flags, []),
      dialyzer_flag_options: Keyword.get(opts, :dialyzer_flag_options, []),
      dialyzer_init_plt: Keyword.get(opts, :dialyzer_init_plt),
      dialyzer_output_plt: Keyword.get(opts, :dialyzer_output_plt),
      discovery_info:
        Keyword.get(opts, :discovery_info, %{
          project_apps: apps,
          dependency_apps: [],
          base_apps: []
        })
    }
  end
end

defmodule Assay.TestSupport.RunnerStub do
  def run(config, opts) do
    send(self(), {:runner_called, config, opts})
    Process.get(:runner_stub_status, :ok)
  end
end

defmodule Assay.TestSupport.IOProxy do
  @moduledoc false

  def start_link(parent \\ self()) do
    {:ok, pid} =
      Task.start_link(fn -> loop(%{buffer: <<>>, parent: parent, pending: [], eof?: false}) end)

    pid
  end

  def push(pid, data) do
    send(pid, {:push, IO.iodata_to_binary(data)})
  end

  def push_eof(pid) do
    send(pid, :push_eof)
  end

  defp loop(state) do
    receive do
      {:push, data} ->
        state
        |> Map.update!(:buffer, &(&1 <> data))
        |> fulfill_pending()
        |> loop()

      :push_eof ->
        %{state | eof?: true}
        |> fulfill_pending()
        |> loop()

      {:io_request, from, reply_as, {:get_line, _encoding, _prompt}} ->
        state
        |> handle_get_line(from, reply_as)
        |> loop()

      {:io_request, from, reply_as, {:get_chars, _enc, _prompt, len}} ->
        state
        |> handle_get_chars(from, reply_as, len)
        |> loop()

      {:io_request, from, reply_as, {:put_chars, _enc, chars}} ->
        send(state.parent, {:io_proxy_output, IO.iodata_to_binary(chars)})
        send(from, {:io_reply, reply_as, :ok})
        loop(state)

      {:io_request, from, reply_as, {:put_chars, chars}} ->
        send(state.parent, {:io_proxy_output, IO.iodata_to_binary(chars)})
        send(from, {:io_reply, reply_as, :ok})
        loop(state)
    end
  end

  defp handle_get_line(state, from, reply_as) do
    case fetch_line(state.buffer, state.eof?) do
      {:reply, reply, rest} ->
        send(from, {:io_reply, reply_as, reply})
        %{state | buffer: rest}

      :pending ->
        update_pending(state, %{type: :line, from: from, reply_as: reply_as})

      {:reply_eof, reply} ->
        send(from, {:io_reply, reply_as, reply})
        state
    end
  end

  defp handle_get_chars(state, from, reply_as, len) do
    case fetch_chars(state.buffer, state.eof?, len) do
      {:reply, reply, rest} ->
        send(from, {:io_reply, reply_as, reply})
        %{state | buffer: rest}

      :pending ->
        update_pending(state, %{type: {:chars, len}, from: from, reply_as: reply_as})

      {:reply_eof, reply} ->
        send(from, {:io_reply, reply_as, reply})
        state
    end
  end

  defp fulfill_pending(state) do
    {pending, buffer} =
      Enum.reduce(state.pending, {[], state.buffer}, fn request, {acc, buf} ->
        fulfill_request(request, buf, state.eof?, acc)
      end)

    %{state | pending: Enum.reverse(pending), buffer: buffer}
  end

  defp fulfill_request(request, buf, eof?, acc) do
    case request.type do
      :line -> fulfill_line_request(request, buf, eof?, acc)
      {:chars, len} -> fulfill_chars_request(request, buf, eof?, len, acc)
    end
  end

  defp fulfill_line_request(request, buf, eof?, acc) do
    case fetch_line(buf, eof?) do
      {:reply, reply, rest} ->
        send(request.from, {:io_reply, request.reply_as, reply})
        {acc, rest}

      :pending ->
        {[request | acc], buf}

      {:reply_eof, reply} ->
        send(request.from, {:io_reply, request.reply_as, reply})
        {acc, buf}
    end
  end

  defp fulfill_chars_request(request, buf, eof?, len, acc) do
    case fetch_chars(buf, eof?, len) do
      {:reply, reply, rest} ->
        send(request.from, {:io_reply, request.reply_as, reply})
        {acc, rest}

      :pending ->
        {[request | acc], buf}

      {:reply_eof, reply} ->
        send(request.from, {:io_reply, request.reply_as, reply})
        {acc, buf}
    end
  end

  defp update_pending(state, request) do
    %{state | pending: state.pending ++ [request]}
  end

  defp fetch_line(<<>>, true), do: {:reply_eof, :eof}
  defp fetch_line(buffer, true), do: {:reply, buffer, <<>>}

  defp fetch_line(buffer, false) do
    case :binary.match(buffer, "\n") do
      {pos, _len} ->
        len = pos + 1
        <<line::binary-size(len), rest::binary>> = buffer
        {:reply, line, rest}

      :nomatch ->
        :pending
    end
  end

  defp fetch_chars(<<>>, true, _len), do: {:reply_eof, :eof}

  defp fetch_chars(buffer, true, len) do
    if byte_size(buffer) >= len do
      <<chunk::binary-size(len), rest::binary>> = buffer
      {:reply, chunk, rest}
    else
      {:reply, buffer, <<>>}
    end
  end

  defp fetch_chars(buffer, false, len) do
    if byte_size(buffer) >= len do
      <<chunk::binary-size(len), rest::binary>> = buffer
      {:reply, chunk, rest}
    else
      :pending
    end
  end
end
