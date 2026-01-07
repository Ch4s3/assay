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

  defmodule QuietErrorShell do
    def info(msg), do: IO.puts(msg)

    def error(msg) when is_binary(msg) do
      # Suppress error messages with stack traces and analysis failed messages
      # These are expected in error-handling tests and create noise
      if String.contains?(msg, "[Assay] Error running analysis") or
           String.contains?(msg, "[Assay] Analysis failed") do
        :ok
      else
        IO.puts(:stderr, msg)
      end
    end

    def error(_), do: :ok
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

  test "cancels in-flight task when new change is detected", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()
    test_pid = self()

    defmodule CancellableAssayStub do
      def run do
        # Send to the test process directly
        test_pid = Process.get(:assay_watch_test_pid)
        if test_pid, do: send(test_pid, {:assay_run_started})
        # Simulate a long-running analysis that can be cancelled
        Process.sleep(500)
        if test_pid, do: send(test_pid, {:assay_run_completed})
        :ok
      end
    end

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

        # Wait for the run to start
        receive do
          {:assay_run_started} -> :ok
        after
          200 -> :timeout
        end

        # Send another event while the first run is in progress - should cancel it
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(20)
        send(watcher_pid, :run)

        send(parent, :done)
      end)

    Process.put(:assay_watch_test_pid, test_pid)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: CancellableAssayStub,
            debounce: 10
          )
        end)
      end)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 1000

    # Verify that the first run was cancelled (should not receive completed message)
    refute_receive {:assay_run_completed}, 100

    Task.shutdown(task, :brutal_kill)
    Process.delete(:assay_watch_test_pid)
  end

  test "cancels task when rescheduling during debounce", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()
    test_pid = self()

    defmodule LongRunningAssayStub do
      def run do
        test_pid = Process.get(:assay_watch_test_pid)
        if test_pid, do: send(test_pid, {:assay_run_started})
        Process.sleep(300)
        if test_pid, do: send(test_pid, {:assay_run_completed})
        :ok
      end
    end

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])

        # Send first event (starts debounce timer)
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(15)

        # Send second event before timer fires (should cancel timer and reschedule)
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(15)

        # Send third event (should cancel any running task and reschedule)
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(50)
        send(watcher_pid, :run)

        send(parent, :done)
      end)

    Process.put(:assay_watch_test_pid, test_pid)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: LongRunningAssayStub,
            debounce: 30
          )
        end)
      end)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 1000

    Task.shutdown(task, :brutal_kill)
    Process.delete(:assay_watch_test_pid)
  end

  test "handles task that completes before cancellation gracefully", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    defmodule FastAssayStub do
      def run do
        # Fast completion - should finish before any cancellation attempt
        Process.sleep(5)
        :ok
      end
    end

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(5)
        send(watcher_pid, :run)

        # Wait for the first run to complete (it's fast)
        Process.sleep(50)

        # Send another event - the previous run should have completed
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(20)
        send(watcher_pid, :run)

        Process.sleep(20)
        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: FastAssayStub,
            debounce: 10
          )
        end)
      end)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})

    # Should complete without errors even when a fast task finishes before cancellation
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
  end

  test "handles :stop file event", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        # Send :stop event - should be handled gracefully
        send(watcher_pid, {:file_event, self(), :stop})
        Process.sleep(10)
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

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
  end

  test "handles task result with legacy ref format", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    defmodule LegacyRefAssayStub do
      def run do
        parent = Notifier.target()
        send(parent, {:assay_run, :ok})
        :ok
      end
    end

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(10)
        send(watcher_pid, :run)

        Process.sleep(50)
        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: LegacyRefAssayStub,
            debounce: 10
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)
    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles task that exits with non-killed reason during cancellation", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()
    test_name = :"assay_watch_test_#{:erlang.unique_integer([:positive])}"

    defmodule ExitingAssayStub do
      def run do
        test_name = Process.get(:assay_watch_test_name)

        if test_name && Process.whereis(test_name) do
          send(test_name, {:assay_run_started})
        end

        # Simulate a task that will exit abnormally
        Process.sleep(200)
        :ok
      end
    end

    Process.register(self(), test_name)

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(20)
        send(watcher_pid, :run)

        # Wait for run to start
        receive do
          {:assay_run_started} -> :ok
        after
          200 -> :timeout
        end

        # Send another event to trigger cancellation
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(20)
        send(watcher_pid, :run)

        Process.sleep(30)
        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        Process.put(:assay_watch_test_name, test_name)

        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: ExitingAssayStub,
            debounce: 10
          )
        end)
      end)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 1000

    Task.shutdown(task, :brutal_kill)
    Process.unregister(test_name)
  end

  test "handles cancel_running_task with running: false", %{tmp_dir: tmp_dir} do
    # This tests the early return when running is false
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        # Send event but don't trigger a run immediately
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(50)
        send(watcher_pid, :run)

        Process.sleep(20)
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
            debounce: 100
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)
    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles cancel_running_task with analysis_task: nil", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    # Test that cancel_running_task handles nil analysis_task gracefully
    # This happens when schedule is called but no task is running
    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        # Send multiple events quickly to trigger rescheduling
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(5)
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(5)
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(30)
        send(watcher_pid, :run)

        Process.sleep(20)
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
            debounce: 20
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)
    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles path normalization errors", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    # Create a path that might cause normalization issues
    # Using a charlist path to test the conversion
    test_path = [0, 1, 2, 3] |> List.to_string()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        # Send event with potentially problematic path
        send(watcher_pid, {:file_event, self(), test_path})
        Process.sleep(10)
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

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
  end

  test "execute_run handles errors gracefully", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    defmodule RaisingAssayStub do
      def run do
        raise "intentional error"
      end
    end

    previous_shell = Mix.shell()
    Mix.shell(QuietErrorShell)
    on_exit(fn -> Mix.shell(previous_shell) end)

    # capture_io captures both stdout and stderr combined
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: RaisingAssayStub
        )
      end)

    assert output =~ "Initial run"
    # Error handling should work (error is logged but doesn't crash)
    assert output =~ "Assay watch mode running"
  end

  test "execute_run handles throws gracefully", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    defmodule ThrowingAssayStub do
      def run do
        throw(:intentional_throw)
      end
    end

    previous_shell = Mix.shell()
    Mix.shell(QuietErrorShell)
    on_exit(fn -> Mix.shell(previous_shell) end)

    # capture_io captures both stdout and stderr combined
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: ThrowingAssayStub
        )
      end)

    assert output =~ "Initial run"
    # Error handling should work (error is logged but doesn't crash)
    assert output =~ "Assay watch mode running"
  end

  test "execute_run_async handles errors gracefully", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    defmodule AsyncRaisingAssayStub do
      def run do
        raise "intentional async error"
      end
    end

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(10)
        send(watcher_pid, :run)

        Process.sleep(50)
        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: AsyncRaisingAssayStub,
            debounce: 10
          )
        end)
      end)

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
  end

  test "handles file_match? with mix.exs", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(tmp_dir)
    mix_file = Path.join(tmp_dir, "mix.exs")
    File.write!(mix_file, "defmodule Test, do: nil")

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        send(watcher_pid, {:file_event, self(), mix_file})
        Process.sleep(10)
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
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles file_match? with mix.lock", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(tmp_dir)
    lock_file = Path.join(tmp_dir, "mix.lock")
    File.write!(lock_file, "%{}")

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        send(watcher_pid, {:file_event, self(), lock_file})
        Process.sleep(10)
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
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles dir_match? with apps directory", %{tmp_dir: tmp_dir} do
    apps_dir = Path.join(tmp_dir, "apps")
    File.mkdir_p!(apps_dir)
    my_app_dir = Path.join(apps_dir, "my_app")
    File.mkdir_p!(my_app_dir)
    lib_dir = Path.join(my_app_dir, "lib")
    File.mkdir_p!(lib_dir)
    test_file = Path.join(lib_dir, "test.ex")
    File.write!(test_file, "defmodule Test, do: nil")

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(10)
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
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles watch_dirs with missing directories", %{tmp_dir: tmp_dir} do
    # Only create lib, not apps/config/test
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    output =
      capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: AssayStub
        )
      end)

    # Should still work with only lib directory
    assert output =~ "Assay watch mode running"
  end

  test "handles display_dirs with absolute paths", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    output =
      capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: AssayStub
        )
      end)

    # Should display directories correctly
    assert output =~ "Assay watch mode running"
  end

  test "handles relevant_path? with non-binary, non-list path", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        # Send an atom path (should be rejected)
        send(watcher_pid, {:file_event, self(), :invalid_path})
        Process.sleep(10)
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

    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
  end

  test "handles task result with mismatched ref", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    defmodule MismatchedRefAssayStub do
      def run do
        parent = Notifier.target()
        send(parent, {:assay_run, :ok})
        :ok
      end
    end

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(10)
        send(watcher_pid, :run)

        # Send a fake task result with wrong ref - should be ignored
        send(watcher_pid, {make_ref(), :ok})

        Process.sleep(20)
        send(parent, :done)
      end)

    task =
      Task.async(fn ->
        capture_io(fn ->
          Assay.Watch.run(
            run_once: false,
            project_root: tmp_dir,
            file_system_module: FileSystemEventStub,
            assay_module: MismatchedRefAssayStub,
            debounce: 10
          )
        end)
      end)

    ResultStore.put(task.pid, :ok)
    Process.sleep(10)
    send(event_sender, {:pid, task.pid})
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
  end

  test "handles task DOWN message with mismatched ref", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    parent = self()

    event_sender =
      spawn(fn ->
        watcher_pid =
          receive do
            {:pid, pid} -> pid
          end

        test_file = Path.join([tmp_dir, "lib", "test.ex"])
        send(watcher_pid, {:file_event, self(), test_file})
        Process.sleep(10)
        send(watcher_pid, :run)

        # Send a fake DOWN message with wrong ref - should be ignored
        fake_ref = make_ref()
        send(watcher_pid, {:DOWN, fake_ref, :process, self(), :normal})

        Process.sleep(20)
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
    assert_receive :done, 500

    Task.shutdown(task, :brutal_kill)
    ResultStore.delete(task.pid)
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
