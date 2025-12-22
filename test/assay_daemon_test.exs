defmodule Assay.DaemonTest do
  use ExUnit.Case, async: true

  alias Assay.Daemon
  alias __MODULE__.{FakeRunner, CapturingRunner, ErrorRunner, IgnoreReportingRunner}

  defmodule FakeRunner do
    def analyze(_config, _opts) do
      %{
        status: :warnings,
        warnings: [
          %{
            text: "lib/foo.ex:1: dialyzer warning",
            match_text: "lib/foo.ex:1: dialyzer warning",
            path: "/tmp/lib/foo.ex",
            relative_path: "lib/foo.ex",
            line: 1,
            code: :unknown
          }
        ],
        ignored: [],
        ignore_path: nil,
        options: []
      }
    end
  end

  setup do
    config = Assay.Config.from_mix_project()
    %{config: config}
  end

  test "assay/analyze returns structured warnings", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "assay/analyze"
    }

    {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

    assert %{
             "result" => %{
               "status" => "warnings",
               "warnings" => [%{"message" => "lib/foo.ex:1: dialyzer warning"}]
             }
           } = reply

    assert new_state.last_result["status"] == "warnings"
    assert new_state.status == :idle
  end

  test "assay/setConfig overrides config", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    request = %{
      "jsonrpc" => "2.0",
      "id" => "2",
      "method" => "assay/setConfig",
      "params" => %{
        "config" => %{
          "apps" => ["assay"],
          "warning_apps" => ["assay"]
        }
      }
    }

    {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

    assert reply["result"]["config"]["apps"] == ["assay"]
    assert new_state.config.apps == [:assay]
    assert new_state.config.warning_apps == [:assay]
  end

  test "assay/analyze normalizes formats and records last result", %{config: config} do
    state = Daemon.new(config: config, runner: CapturingRunner)

    analyze_request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "assay/analyze",
      "params" => %{"formats" => ["json", 123, :github]}
    }

    {reply, analyzed_state, :continue} = Daemon.handle_rpc(analyze_request, state)

    assert reply["result"]["status"] == "warnings"
    assert analyzed_state.last_result["warnings"] != nil
    assert_receive {:formats_seen, [:json, :text, :github]}

    status_request = %{"jsonrpc" => "2.0", "id" => 2, "method" => "assay/getStatus"}
    {status_reply, _state, :continue} = Daemon.handle_rpc(status_request, analyzed_state)

    assert status_reply["result"]["state"] == "idle"
    assert status_reply["result"]["last_result"]["status"] == "warnings"
  end

  test "assay/getConfig reports overrides and project metadata", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    overrides = %{
      "config" => %{
        "apps" => ["assay"],
        "warning_apps" => [:assay],
        "cache_dir" => "tmp/cache",
        "plt_path" => "tmp/cache/plt",
        "ignore_file" => "dialyzer_ignore.exs"
      }
    }

    {_, overridden_state, :continue} =
      Daemon.handle_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "assay/setConfig", "params" => overrides}, state)

    {get_reply, _final_state, :continue} =
      Daemon.handle_rpc(%{"jsonrpc" => "2.0", "id" => 2, "method" => "assay/getConfig"}, overridden_state)

    config_payload = get_reply["result"]["config"]
    assert config_payload["apps"] == ["assay"]
    assert config_payload["warning_apps"] == ["assay"]
    assert config_payload["cache_dir"] == "tmp/cache"
    assert get_reply["result"]["overrides"]["apps"] == ["assay"]
  end

  test "assay/setConfig rejects unsupported keys", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    params = %{"config" => %{"unknown" => "value"}}
    request = %{"jsonrpc" => "2.0", "id" => "bad", "method" => "assay/setConfig", "params" => params}

    {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

    assert reply["error"]["code"] == -32_602
    assert new_state == state
  end

  test "assay/analyze surfaces runner errors", %{config: config} do
    state = Daemon.new(config: config, runner: ErrorRunner)

    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "assay/analyze"}

    {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

    assert reply["error"]["code"] == -32_000
    assert reply["error"]["message"] =~ "boom"
    assert new_state.status == :idle
  end

  test "assay/analyze displays relative ignore paths", %{config: config} do
    state = Daemon.new(config: config, runner: IgnoreReportingRunner)

    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "assay/analyze"}
    {reply, _state, :continue} = Daemon.handle_rpc(request, state)

    assert reply["result"]["ignore_file"] == "dialyzer_ignore.exs"
  end

  test "unknown methods return JSON-RPC errors", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    request = %{"jsonrpc" => "2.0", "id" => 7, "method" => "assay/unknown"}
    {reply, _state, :continue} = Daemon.handle_rpc(request, state)

    assert reply["error"]["code"] == -32_601
  end

  test "malformed requests return nil reply", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)
    {reply, _state, :continue} = Daemon.handle_rpc(%{}, state)
    assert reply == nil
  end

  test "assay/shutdown signals stop", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    {reply, _state, action} =
      Daemon.handle_rpc(%{"jsonrpc" => "2.0", "id" => 3, "method" => "assay/shutdown"}, state)

    assert reply["result"]["status"] == "shutting_down"
    assert action == :stop
  end

  defmodule CapturingRunner do
    def analyze(config, opts) do
      send(self(), {:formats_seen, opts[:formats]})
      FakeRunner.analyze(config, opts)
    end
  end

  defmodule ErrorRunner do
    def analyze(_config, _opts), do: raise("boom")
  end

  defmodule IgnoreReportingRunner do
    def analyze(config, _opts) do
      result = FakeRunner.analyze(config, [])

      Map.put(result, :ignore_path, Path.join(config.project_root, "dialyzer_ignore.exs"))
    end
  end
end
