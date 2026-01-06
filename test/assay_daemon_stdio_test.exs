defmodule Assay.DaemonSTDIOTest do
  use ExUnit.Case, async: false

  alias Assay.{Config, Daemon}
  alias Assay.TestSupport.IOProxy

  defmodule StubRunner do
    def analyze(_config, _opts) do
      %{status: :ok, warnings: [], ignored: [], ignore_path: nil}
    end
  end

  setup do
    previous_shell = Mix.shell()

    root =
      Path.join(System.tmp_dir!(), "assay-daemon-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    config = Config.from_mix_project(project_root: root)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf(root)
    end)

    %{config: config}
  end

  test "serve responds to JSON-RPC and invalid JSON", %{config: config} do
    proxy = IOProxy.start_link(self())

    task =
      Task.async(fn ->
        Process.group_leader(self(), proxy)
        Daemon.serve(config: config, runner: StubRunner)
      end)

    send_json(proxy, %{"id" => 1, "method" => "assay/getStatus"})
    assert_receive {:io_proxy_output, status_line}, 500
    {:ok, status} = JSON.decode(String.trim(status_line))
    assert status["result"]["state"] == "idle"

    IOProxy.push(proxy, "not-json\n")
    assert_receive {:io_proxy_output, error_line}, 500
    error = JSON.decode!(String.trim(error_line))
    assert error["error"]["code"] == -32_700

    IOProxy.push_eof(proxy)
    assert Task.yield(task, 500)
  end

  defp send_json(proxy, payload) do
    IOProxy.push(proxy, JSON.encode!(payload) <> "\n")
  end
end
