defmodule Mix.Tasks.AssayTest do
  use ExUnit.Case, async: false

  alias Assay.TestSupport.{ConfigStub, RunnerStub}
  alias Mix.Tasks.Assay
  alias Mix.Tasks.Assay.{Clean, Daemon, Mcp, PrintConfig, Watch}

  defmodule DaemonStub do
    def serve do
      send(self(), :daemon_served)
    end
  end

  defmodule MCPStub do
    def serve do
      send(self(), :mcp_served)
    end
  end

  defmodule WatchStub do
    def run do
      send(self(), :watch_started)
    end
  end

  defmodule CleanConfigStub do
    def from_mix_project(_opts \\ []) do
      root = Process.get(:assay_clean_root) || "/tmp/assay-clean"
      ConfigStub.from_mix_project(project_root: root)
    end
  end

  setup do
    Mix.Task.clear()
    Application.put_env(:assay, :config_module, ConfigStub)
    Application.put_env(:assay, :runner_module, RunnerStub)

    on_exit(fn ->
      Application.delete_env(:assay, :config_module)
      Application.delete_env(:assay, :runner_module)
      Application.delete_env(:assay, :daemon_module)
      Application.delete_env(:assay, :mcp_module)
      Application.delete_env(:assay, :watch_module)
      Process.delete(:runner_stub_status)
    end)

    :ok
  end

  test "run forwards CLI options to Assay.run" do
    Process.put(:runner_stub_status, :ok)

    ExUnit.CaptureIO.capture_io(fn ->
      Assay.run(["--print-config", "--format", "elixir"])
    end)

    assert_received {:config_opts, opts}
    assert Keyword.get(opts, :print_config)
    assert Keyword.get(opts, :formats) == [:elixir]
    assert_received {:runner_called, _config, runner_opts}
    assert Keyword.get(runner_opts, :print_config)
    assert Keyword.get(runner_opts, :formats) == [:elixir]
  end

  test "run accepts symbolic app selectors from CLI" do
    Process.put(:runner_stub_status, :ok)

    ExUnit.CaptureIO.capture_io(fn ->
      Assay.run(["--apps", "project+deps", "--warning-apps", "current"])
    end)

    assert_received {:config_opts, opts}
    assert Keyword.get(opts, :apps) == ["project+deps"]
    assert Keyword.get(opts, :warning_apps) == ["current"]
  end

  test "run exits with shutdown status when warnings are reported" do
    Process.put(:runner_stub_status, :warnings)

    capture_io(fn ->
      assert catch_exit(Assay.run([])) == {:shutdown, 1}
    end)

    assert_received {:runner_called, _config, runner_opts}
    refute Keyword.get(runner_opts, :print_config)
    assert Keyword.get(runner_opts, :formats) == [:text]
  end

  test "run raises on unsupported formats" do
    assert_raise Mix.Error, fn ->
      Assay.run(["--format", "yaml"])
    end
  end

  test "run raises when extra arguments are supplied" do
    assert_raise Mix.Error, fn ->
      Assay.run(["unexpected"])
    end
  end

  test "assay.daemon task boots the daemon" do
    Application.put_env(:assay, :daemon_module, DaemonStub)

    capture_io(fn ->
      Daemon.run([])
    end)

    assert_received :daemon_served
  end

  test "assay.print_config forwards to mix assay with print flag" do
    Process.put(:runner_stub_status, :ok)

    ExUnit.CaptureIO.capture_io(fn ->
      PrintConfig.run(["--format", "llm"])
    end)

    assert_received {:runner_called, _config, runner_opts}
    assert runner_opts[:print_config]
    assert runner_opts[:formats] == [:llm]
  end

  test "assay.clean removes the cache directory" do
    tmp_root = Path.join(System.tmp_dir!(), "assay-clean-#{System.unique_integer([:positive])}")
    cache_dir = Path.join(tmp_root, "_build/assay")
    File.mkdir_p!(Path.join(cache_dir, "nested"))
    Process.put(:assay_clean_root, tmp_root)

    Application.put_env(:assay, :config_module, CleanConfigStub)

    capture_io(fn ->
      Clean.run([])
    end)

    refute File.exists?(cache_dir)

    Application.put_env(:assay, :config_module, ConfigStub)
  after
    Process.delete(:assay_clean_root)
  end

  test "assay.clean rejects unexpected arguments" do
    assert_raise Mix.Error, fn ->
      Clean.run(["unexpected"])
    end
  end

  test "assay.mcp task boots the MCP server" do
    Application.put_env(:assay, :mcp_module, MCPStub)

    capture_io(fn ->
      Mcp.run([])
    end)

    assert_received :mcp_served
  end

  test "assay.watch task boots the watch mode" do
    Application.put_env(:assay, :watch_module, WatchStub)

    capture_io(fn ->
      Watch.run([])
    end)

    assert_received :watch_started
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
