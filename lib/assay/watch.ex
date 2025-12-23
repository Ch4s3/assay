defmodule Assay.Watch do
  @moduledoc false

  @default_dirs ["lib", "apps", "config", "test"]
  @default_files ["mix.exs", "mix.lock"]
  @ignored_segments ["/_build/", "/deps/", "/.git/"]

  @doc """
  Runs incremental Dialyzer once and then re-runs it whenever watched files
  change. Intended for local developer use (`mix assay.watch`).

  Returns `:ok` when `run_once: true`, otherwise never returns (runs indefinitely).
  """
  @spec run(keyword()) :: :ok | no_return()
  def run(opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    dirs = watch_dirs(project_root)
    fs_mod = watch_file_system(opts)
    assay_mod = watch_runner(opts)
    run_once? = Keyword.get(opts, :run_once, false)

    watcher =
      case fs_mod.start_link(
             dirs: dirs,
             latency: Keyword.get(opts, :latency, 500)
           ) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Mix.shell().error("[Assay] Failed to start file watcher: #{inspect(reason)}")
          exit({:shutdown, :watcher_start_failed})

        other ->
          Mix.shell().error("[Assay] Unexpected file watcher response: #{inspect(other)}")
          exit({:shutdown, :watcher_unexpected_response})
      end

    case fs_mod.subscribe(watcher) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("[Assay] Failed to subscribe to file watcher: #{inspect(reason)}")
        stop_watcher(fs_mod, watcher)
        exit({:shutdown, :watcher_subscribe_failed})

      other ->
        Mix.shell().error("[Assay] Unexpected subscribe response: #{inspect(other)}")
        stop_watcher(fs_mod, watcher)
        exit({:shutdown, :watcher_subscribe_unexpected})
    end

    Mix.shell().info(
      "Assay watch mode running (watching #{Enum.join(display_dirs(dirs, project_root), ", ")})."
    )

    Mix.shell().info("Press Ctrl+C to stop.")

    state =
      %{
        project_root: project_root,
        debounce_ms: Keyword.get(opts, :debounce, 300),
        timer: nil,
        assay: assay_mod,
        watcher: watcher,
        fs_mod: fs_mod,
        running: false,
        analysis_task: nil
      }

    # Monitor the watcher process
    ref = Process.monitor(watcher)

    state =
      state
      |> execute_run_async("Initial run")

    if run_once? do
      stop_watcher(fs_mod, watcher)
      :ok
    else
      loop(state, ref)
    end
  end

  defp loop(state, ref) do
    receive do
      {:file_event, _pid, {path, _events}} ->
        loop(maybe_schedule(path, state), ref)

      {:file_event, _pid, :stop} ->
        loop(state, ref)

      {:file_event, _pid, path} ->
        loop(maybe_schedule(path, state), ref)

      :run ->
        loop(execute_run_async(state, "Change detected"), ref)

      {task_ref, result} when is_reference(task_ref) ->
        if not is_nil(state.analysis_task) and task_ref == state.analysis_task do
          case result do
            :ok -> Mix.shell().info("[Assay] No warnings")
            :warnings -> Mix.shell().info("[Assay] Warnings detected")
            :error -> Mix.shell().error("[Assay] Analysis failed")
          end
          # Clear the running flag and task reference
          new_state = %{state | running: false, analysis_task: nil}
          loop(new_state, ref)
        else
          loop(state, ref)
        end

      {:DOWN, ^ref, :process, _pid, reason} ->
        Mix.shell().error("[Assay] File watcher process crashed: #{inspect(reason)}")
        exit({:shutdown, :watcher_crashed})

      {:DOWN, task_ref, :process, _pid, _reason} when not is_nil(state.analysis_task) and task_ref == state.analysis_task ->
        # Task completed normally (DOWN message after result)
        new_state = %{state | running: false, analysis_task: nil}
        loop(new_state, ref)

      _other ->
        # Ignore unexpected messages (could be from other processes)
        loop(state, ref)
    end
  end

  defp execute_run(state, reason) do
    cancel_timer(state.timer)

    # If a run is already in progress, skip this one (debounce will reschedule)
    if state.running do
      Mix.shell().info("[Assay] Run already in progress, skipping...")
      state
    else
      Mix.shell().info("[Assay] #{reason}, running incremental Dialyzer...")

      running_state = %{state | running: true, timer: nil}

      result =
        try do
          state.assay.run()
        rescue
          error ->
            Mix.shell().error(
              "[Assay] Error running analysis: #{Exception.format(:error, error, __STACKTRACE__)}"
            )

            :error
        catch
          kind, reason ->
            Mix.shell().error(
              "[Assay] Error running analysis: #{Exception.format(kind, reason, __STACKTRACE__)}"
            )

            :error
        end

      case result do
        :ok -> Mix.shell().info("[Assay] No warnings")
        :warnings -> Mix.shell().info("[Assay] Warnings detected")
        :error -> Mix.shell().error("[Assay] Analysis failed")
      end

      %{running_state | running: false}
    end
  end

  defp execute_run_async(state, reason) do
    cancel_timer(state.timer)

    # If a run is already in progress, skip this one (debounce will reschedule)
    if state.running do
      Mix.shell().info("[Assay] Run already in progress, skipping...")
      state
    else
      Mix.shell().info("[Assay] #{reason}, running incremental Dialyzer...")

      # Run analysis in a separate task so we can continue receiving file events
      task =
        Task.async(fn ->
          try do
            state.assay.run()
          rescue
            error ->
              Mix.shell().error(
                "[Assay] Error running analysis: #{Exception.format(:error, error, __STACKTRACE__)}"
              )

              :error
          catch
            kind, reason ->
              Mix.shell().error(
                "[Assay] Error running analysis: #{Exception.format(kind, reason, __STACKTRACE__)}"
              )

              :error
          end
        end)

      # Store the task ref so we can match on completion messages
      %{state | running: true, timer: nil, analysis_task: task.ref}
    end
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
    # Check if path starts with any of the default dirs
    # For umbrella projects, files in apps/*/lib/ should match
    matches = Enum.any?(@default_dirs, fn dir ->
      String.starts_with?(relative, dir <> "/") or
      relative == dir or
      String.starts_with?(relative, dir)
    end)
    matches
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

  defp stop_watcher(fs_mod, watcher) do
    if function_exported?(fs_mod, :stop, 1) do
      try do
        fs_mod.stop(watcher)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    else
      # If stop/1 doesn't exist, try to kill the process
      if Process.alive?(watcher) do
        Process.exit(watcher, :normal)
      end
    end
  end
end
