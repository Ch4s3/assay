defmodule Assay.MCPSTDIOTest do
  use ExUnit.Case, async: false

  alias Assay.{MCP, Daemon}
  alias Assay.TestSupport.IOProxy

  defmodule StubRunner do
    def analyze(_config, opts) do
      send(self(), {:runner_opts, opts})
      %{status: :ok, warnings: [], ignored: [], ignore_path: nil, options: []}
    end
  end

  setup do
    previous_shell = Mix.shell()
    on_exit(fn -> Mix.shell(previous_shell) end)

    config = Assay.Config.from_mix_project(project_root: temp_dir())
    daemon = Daemon.new(config: config, runner: StubRunner)
    %{daemon: daemon}
  end

  test "serve processes framed requests", %{daemon: daemon} do
    {proxy, task} = start_server(daemon)

    send_frame(proxy, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
    assert_receive {:io_proxy_output, init_frame}, 500
    assert decode_frame(init_frame)["result"]["protocolVersion"] == "2024-11-05"

    send_frame(proxy, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
    assert_receive {:io_proxy_output, tools_frame}, 500
    assert %{"result" => %{"tools" => [%{"name" => "assay.analyze"}]}} = decode_frame(tools_frame)

    send_frame(proxy, %{"jsonrpc" => "2.0", "id" => 3, "method" => "shutdown"})
    assert_receive {:io_proxy_output, shutdown_frame}, 500
    assert decode_frame(shutdown_frame)["result"]["status"] == "shutting_down"

    assert Task.yield(task, 500), "server did not exit after shutdown"
  end

  test "invalid JSON results in framed errors", %{daemon: daemon} do
    {proxy, task} = start_server(daemon)

    send_raw(proxy, "invalid json\n")
    assert_receive {:io_proxy_output, error_frame}, 500
    assert decode_frame(error_frame)["error"]["code"] == -32_700

    send_raw(proxy, JSON.encode!(%{"jsonrpc" => "2.0", "id" => 4, "method" => "exit"}) <> "\n")
    assert_receive {:io_proxy_output, exit_frame}, 500
    assert decode_frame(exit_frame)["result"]["status"] == "shutting_down"
    assert Task.yield(task, 500)
  end

  defp start_server(daemon) do
    proxy = IOProxy.start_link(self())

    task =
      Task.async(fn ->
        Process.group_leader(self(), proxy)
        MCP.serve(daemon: daemon, halt_on_stop?: false)
      end)

    {proxy, task}
  end

  defp send_frame(proxy, payload) do
    json = JSON.encode!(payload)
    frame = "Content-Length: #{byte_size(json)}\r\n\r\n" <> json
    IOProxy.push(proxy, frame)
  end

  defp send_raw(proxy, data), do: IOProxy.push(proxy, data)

  defp decode_frame(frame) do
    [_headers, json] = String.split(frame, "\r\n\r\n", parts: 2)
    {:ok, decoded} = JSON.decode(json)
    decoded
  end

  defp temp_dir do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "assay-mcp-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(path)
    path
  end
end
