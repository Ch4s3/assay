defmodule Assay.Watch do
  @moduledoc false

  @default_dirs ["lib", "apps", "config", "test"]
  @default_files ["mix.exs", "mix.lock"]
  @ignored_segments ["/_build/", "/deps/", "/.git/"]

  @doc """
  Runs incremental Dialyzer once and then re-runs it whenever watched files
  change. Intended for local developer use (`mix assay.watch`).
  """
  @spec run(keyword()) :: no_return()
  def run(opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    dirs = watch_dirs(project_root)
    fs_mod = watch_file_system(opts)
    assay_mod = watch_runner(opts)
    run_once? = Keyword.get(opts, :run_once, false)

    {:ok, watcher} =
      fs_mod.start_link(
        dirs: dirs,
        latency: Keyword.get(opts, :latency, 500)
      )

    fs_mod.subscribe(watcher)

    Mix.shell().info(
      "Assay watch mode running (watching #{Enum.join(display_dirs(dirs, project_root), ", ")})."
    )

    Mix.shell().info("Press Ctrl+C to stop.")

    state =
      %{
        project_root: project_root,
        debounce_ms: Keyword.get(opts, :debounce, 300),
        timer: nil,
        assay: assay_mod
      }

    state =
      state
      |> execute_run("Initial run")

    if run_once? do
      :ok
    else
      loop(state)
    end
  end

  defp loop(state) do
    receive do
      {:file_event, _pid, {path, _events}} ->
        loop(maybe_schedule(path, state))

      {:file_event, _pid, :stop} ->
        loop(state)

      {:file_event, _pid, path} ->
        loop(maybe_schedule(path, state))

      :run ->
        state
        |> execute_run("Change detected")
        |> loop()
    end
  end

  defp execute_run(state, reason) do
    cancel_timer(state.timer)

    Mix.shell().info("[Assay] #{reason}, running incremental Dialyzer...")

    case state.assay.run() do
      :ok -> Mix.shell().info("[Assay] No warnings")
      :warnings -> Mix.shell().info("[Assay] Warnings detected")
    end

    %{state | timer: nil}
  end

  defp maybe_schedule(path, state) do
    if relevant_path?(path, state.project_root) do
      schedule(state)
    else
      state
    end
  end

  defp schedule(%{timer: nil} = state) do
    timer = Process.send_after(self(), :run, state.debounce_ms)
    %{state | timer: timer}
  end

  defp schedule(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp watch_dirs(project_root) do
    dirs =
      @default_dirs
      |> Enum.map(&Path.join(project_root, &1))
      |> Enum.filter(&File.dir?/1)

    [project_root | dirs]
    |> Enum.uniq()
  end

  defp display_dirs(dirs, root) do
    Enum.map(dirs, fn dir ->
      case Path.relative_to(dir, root) do
        relative when relative != dir -> relative
        _ -> dir
      end
    end)
  end

  defp relevant_path?(path, root) when is_list(path) do
    path
    |> IO.chardata_to_string()
    |> relevant_path?(root)
  end

  defp relevant_path?(path, root) when is_binary(path) do
    normalized = normalize_path(path)

    cond do
      ignored_path?(normalized) ->
        false

      file_match?(normalized, root) ->
        true

      dir_match?(normalized, root) ->
        true

      true ->
        false
    end
  end

  defp relevant_path?(_path, _root), do: false

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> to_string()
  rescue
    _ -> to_string(path)
  end

  defp ignored_path?(path) do
    Enum.any?(@ignored_segments, &String.contains?(path, &1))
  end

  defp file_match?(path, root) do
    relative = relative_to_root(path, root)
    relative in @default_files
  end

  defp dir_match?(path, root) do
    relative = relative_to_root(path, root)
    Enum.any?(@default_dirs, &String.starts_with?(relative, &1))
  end

  defp relative_to_root(path, root) do
    Path.relative_to(path, root)
  rescue
    _ -> path
  end

  defp watch_file_system(opts) do
    Keyword.get(opts, :file_system_module) ||
      Application.get_env(:assay, :file_system_module, FileSystem)
  end

  defp watch_runner(opts) do
    Keyword.get(opts, :assay_module) ||
      Application.get_env(:assay, :assay_module, Assay)
  end
end
