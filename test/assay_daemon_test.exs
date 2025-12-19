defmodule Assay.DaemonTest do
  use ExUnit.Case, async: true

  alias Assay.Daemon

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

  test "assay/shutdown signals stop", %{config: config} do
    state = Daemon.new(config: config, runner: FakeRunner)

    {reply, _state, action} =
      Daemon.handle_rpc(%{"jsonrpc" => "2.0", "id" => 3, "method" => "assay/shutdown"}, state)

    assert reply["result"]["status"] == "shutting_down"
    assert action == :stop
  end
end
