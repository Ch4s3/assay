defmodule Assay.WatchTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defmodule FileSystemStub do
    def start_link(opts) do
      send(self(), {:file_system_start, opts})
      {:ok, self()}
    end

    def subscribe(_pid) do
      send(self(), :file_system_subscribed)
      :ok
    end
  end

  defmodule AssayStub do
    def run do
      result = Process.get(:assay_watch_result, :ok)
      send(self(), {:assay_run, result})
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
    end)

    assert_received {:file_system_start, opts}
    assert Keyword.has_key?(opts, :dirs)
    assert_received :file_system_subscribed
    assert_received {:assay_run, :ok}
  end

  test "run reports warnings when assay returns warnings", %{tmp_dir: tmp_dir} do
    Process.put(:assay_watch_result, :warnings)

    output =
      capture_io(fn ->
        Assay.Watch.run(
          run_once: true,
          project_root: tmp_dir,
          file_system_module: FileSystemStub,
          assay_module: AssayStub
        )
      end)

    assert output =~ "Warnings detected"
    assert_received {:assay_run, :warnings}
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
