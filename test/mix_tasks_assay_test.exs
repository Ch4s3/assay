defmodule Mix.Tasks.AssayTest do
  use ExUnit.Case, async: false

  alias Assay.TestSupport.{ConfigStub, RunnerStub}
  alias Mix.Tasks.Assay
  alias Mix.Tasks.Assay.{Daemon, Mcp, Watch}

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

    assert_received {:config_opts, [print_config: true, formats: [:elixir]]}
    assert_received {:runner_called, _config, [print_config: true, formats: [:elixir]]}
  end

  test "run exits with shutdown status when warnings are reported" do
    Process.put(:runner_stub_status, :warnings)

    assert catch_exit(Assay.run([])) == {:shutdown, 1}
    assert_received {:runner_called, _config, [print_config: false, formats: [:text]]}
  end

  test "run raises on unsupported formats" do
    assert_raise Mix.Error, fn ->
      Assay.run(["--format", "json"])
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
