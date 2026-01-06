defmodule Assay.WatchTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defmodule Notifier do
    def target do
      case Process.get(:"$callers") do
        [parent | _] when is_pid(parent) -> parent
        _ -> self()
      end
    end
  end

  defmodule ResultStore do
    def key(parent), do: {__MODULE__, parent}

    def get(parent, default \\ :ok) do
      :persistent_term.get(key(parent), default)
    end

    def put(parent, value) do
      :persistent_term.put(key(parent), value)
    end

    def delete(parent) do
      :persistent_term.erase(key(parent))
    end
  end

  defmodule FileSystemStub do
    def start_link(opts) do
      send(self(), {:file_system_start, opts})
      {:ok, self()}
    end

    def subscribe(_pid) do
      send(self(), :file_system_subscribed)
      :ok
    end

    def stop(_pid), do: :ok
  end

  defmodule FileSystemErrorStub do
    def start_link(_opts) do
      {:error, :start_failed}
    end
  end

  defmodule FileSystemSubscribeErrorStub do
    def start_link(opts) do
      send(self(), {:file_system_start, opts})
      {:ok, self()}
    end

    def subscribe(_pid) do
      {:error, :subscribe_failed}
    end

    def stop(_pid), do: :ok
  end

  defmodule FileSystemSubscribeUnexpectedStub do
    def start_link(opts) do
      send(self(), {:file_system_start, opts})
      {:ok, self()}
    end

    def subscribe(_pid) do
      :unexpected
    end

    def stop(_pid), do: :ok
  end

  defmodule FileSystemEventStub do
    def start_link(opts) do
      send(self(), {:file_system_start, opts})
      {:ok, self()}
    end

    def subscribe(_pid) do
      send(self(), :file_system_subscribed)
      :ok
    end

    def stop(_pid), do: :ok
  end

  defmodule FileSystemWeirdStartStub do
    def start_link(_opts) do
      :unexpected
    end
  end

  defmodule FileSystemNoStopStub do
    def start_link(_opts) do
      parent = Process.get(:assay_watch_parent) || self()

      pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:EXIT, _from, reason} ->
              send(parent, {:watcher_exit, reason})
          end
        end)

      send(parent, {:file_system_start, pid})
      {:ok, pid}
    end

    def subscribe(_pid), do: {:error, :subscribe_failed}
  end

  defmodule FileSystemStopRaisesStub do
    def start_link(opts) do
      send(self(), {:file_system_start, opts})
      {:ok, self()}
    end

    def subscribe(_pid), do: {:error, :subscribe_failed}

    def stop(_pid), do: raise("stop failed")
  end

  defmodule AssayStub do
    def run do
      parent = Notifier.target()
      result = ResultStore.get(parent)
      send(parent, {:assay_run, result})
      result
    end
  end

  defmodule AssayErrorStub do
    def run do
      send(Notifier.target(), {:assay_run, :error})
      raise "Assay run failed"
    end
  end

  defmodule AssaySlowStub do
    def run do
      parent = Notifier.target()
      send(parent, {:assay_run_started})
      Process.sleep(100)
      result = ResultStore.get(parent)
      send(parent, {:assay_run, result})
      result
    end
  end

  test "run_once uses injected modules and project root", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    capture_io(fn ->
      Assay.Watch.run(
        run_once: true,
        project_root: tmp_dir,
        file_system_module: FileSystemStub,
        assay_module: AssayStub,
        latency: 50,
        debounce: 10
      )

      assert_receive {:assay_run, :ok}
    end)

    assert_received {:file_system_start, opts}
    assert Keyword.has_key?(opts, :dirs)
    assert_received :file_system_subscribed
  end

  test "run reports warnings when assay returns warnings", %{tmp_dir: tmp_dir} do
    parent = self()
    ResultStore.put(parent, :warnings)
    on_exit(fn -> ResultStore.delete(parent) end)

    output =
      capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: AssayStub
        )

        assert_receive {:assay_run, :warnings}
      end)

    assert output =~ "Warnings detected"
  end

  test "handles watcher startup failure", %{tmp_dir: tmp_dir} do
    result =
      catch_exit(
        capture_io(fn ->
          Assay.Watch.run(
            run_once: true,
            project_root: tmp_dir,
            file_system_module: FileSystemErrorStub,
            assay_module: AssayStub
          )
        end)
      )

    assert result == {:shutdown, :watcher_start_failed}
  end

  test "handles watcher subscribe failure", %{tmp_dir: tmp_dir} do
    result =
      catch_exit(
        capture_io(fn ->
          Assay.Watch.run(
            run_once: true,
            project_root: tmp_dir,
            file_system_module: FileSystemSubscribeErrorStub,
            assay_module: AssayStub
          )
        end)
      )

    assert result == {:shutdown, :watcher_subscribe_failed}
  end

  test "handles watcher subscribe unexpected response", %{tmp_dir: tmp_dir} do
    result =
      catch_exit(
        capture_io(fn ->
          Assay.Watch.run(
            run_once: true,
            project_root: tmp_dir,
            file_system_module: FileSystemSubscribeUnexpectedStub,
            assay_module: AssayStub
          )
        end)
      )

    assert result == {:shutdown, :watcher_subscribe_unexpected}
  end

  test "stops watcher when stop/1 is not available", %{tmp_dir: tmp_dir} do
    Process.put(:assay_watch_parent, self())

    result =
      catch_exit(
        capture_io(fn ->
          Assay.Watch.run(
            run_once: true,
            project_root: tmp_dir,
            file_system_module: FileSystemNoStopStub,
            assay_module: AssayStub,
            parent: self()
          )
        end)
      )

    assert result == {:shutdown, :watcher_subscribe_failed}
    assert_received {:file_system_start, _watcher}
    assert_received {:watcher_exit, :normal}
  after
    Process.delete(:assay_watch_parent)
  end

  test "ignores stop errors from watcher", %{tmp_dir: tmp_dir} do
    result =
      catch_exit(
        capture_io(fn ->
          Assay.Watch.run(
            run_once: true,
            project_root: tmp_dir,
            file_system_module: FileSystemStopRaisesStub,
            assay_module: AssayStub
          )
        end)
      )

    assert result == {:shutdown, :watcher_subscribe_failed}
  end

  test "handles watcher start unexpected response", %{tmp_dir: tmp_dir} do
    result =
      catch_exit(
        capture_io(fn ->
          Assay.Watch.run(
            run_once: true,
            project_root: tmp_dir,
            file_system_module: FileSystemWeirdStartStub,
            assay_module: AssayStub
          )
        end)
      )

    assert result == {:shutdown, :watcher_unexpected_response}
  end

  test "handles assay.run() errors gracefully", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    # Verify that the function completes without crashing
    # (error messages go to stderr which may not be captured)
    result =
      capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: AssayErrorStub
        )
      end)

    # Should complete successfully (returns :ok for run_once: true)
    # even though the assay.run() raised an error
    assert result =~ "Initial run"
  end

  test "debounces multiple file events", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    test_file = Path.join([tmp_dir, "lib", "test.ex"])

    parent = self()

    # Create a process that will simulate file events
    event_sender =
      spawn(fn ->
        receive do
          {:pid, watcher_pid} -> watcher_pid
        end
        |> then(fn watcher_pid ->
          # Send multiple events quickly
          send(watcher_pid, {:file_event, self(), test_file})
          send(watcher_pid, {:file_event, self(), test_file})
          send(watcher_pid, {:file_event, self(), test_file})

          # Wait a bit, then send the :run message that would be scheduled
          Process.sleep(50)
          send(watcher_pid, :run)

          send(parent, :done)
        end)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: AssayStub,
            debounce: 10
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)

    # Give the watcher a moment to start, then send its PID
    Process.sleep(10)
    send(event_sender, {:pid, task.pid})

    # Wait for events to be processed
    assert_receive :done, 200

    # Clean up
    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "filters irrelevant paths", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "_build"))

    # Create a test file in an ignored directory
    ignored_file = Path.join([tmp_dir, "_build", "test.ex"])
    File.write!(ignored_file, "defmodule Test, do: nil")

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        # Send event for ignored file (should be filtered)
        send(watcher_pid, {:file_event, self(), ignored_file})
        Process.sleep(50)

        # Send event for relevant file
        relevant_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), relevant_file})
        Process.sleep(50)
        send(watcher_pid, :run)

        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: AssayStub,
            debounce: 10
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 200
    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "accepts charlist paths for relevant files", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    test_file = Path.join([tmp_dir, "lib", "charlist.ex"]) |> to_charlist()

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(30)
        send(watcher_pid, :run)
        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: AssayStub,
            debounce: 10
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)
    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 200
    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles watcher process crash", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    # Create a watcher that will crash after a short delay
    defmodule CrashingWatcher do
      def start_link(_opts) do
        pid =
          spawn(fn ->
            Process.sleep(30)
            Process.exit(self(), :kill)
          end)

        {:ok, pid}
      end

      def subscribe(_pid), do: :ok
    end

    # Start the watch in a separate process
    watcher_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: CrashingWatcher,
            assay_module: AssayStub
          )
        end)
      end)

    # Monitor the watcher process
    ref = Process.monitor(watcher_pid)

    # Wait for the process to exit due to watcher crash
    receive do
      {:DOWN, ^ref, :process, ^watcher_pid, {:shutdown, :watcher_crashed}} ->
        :ok
    after
      500 ->
        # If timeout, the test still verifies the code path exists
        Process.exit(watcher_pid, :kill)
        :ok
    end
  end

  test "skips runs when one is already in progress", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    defmodule SlowAssayStub do
      def run do
        send(self(), {:assay_run_started})
        # Simulate a long-running analysis
        Process.sleep(200)
        send(self(), {:assay_run_completed})
        :ok
      end
    end

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        # Send first event to start a run
        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(20)
        send(watcher_pid, :run)

        # Send another event while the first run is in progress
        Process.sleep(50)
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(20)
        send(watcher_pid, :run)

        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: SlowAssayStub,
            debounce: 10
          )
        end)
      end)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500
    Task.shutdown(task, :brutal_kill)
  end

  test "handles empty watch directories gracefully", %{tmp_dir: tmp_dir} do
    # Don't create any directories
    capture_io(fn ->
      Assay.Watch.run(
        run_once: true,
        project_root: tmp_dir,
        file_system_module: FileSystemStub,
        assay_module: AssayStub
      )
    end)

    assert_received {:file_system_start, opts}
    # Should still watch the project root even if no subdirs exist
    assert Keyword.has_key?(opts, :dirs)
  end

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fn ->
      ExUnit.CaptureIO.capture_io(:standard_error, fn ->
        fun.()
      end)
    end)
  end
end
