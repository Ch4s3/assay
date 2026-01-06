defmodule Assay.DaemonTestRunner do
  @moduledoc false

  def analyze(config, opts) do
    if pid = Process.get(:assay_daemon_test_pid) do
      send(pid, {:formats, opts[:formats]})
    end

    %{
      status: :ok,
      warnings: [
        %{
          text: "warning",
          match_text: "match",
          path: Path.join(config.project_root, "lib/sample.ex"),
          relative_path: "lib/sample.ex",
          line: 3,
          column: 1,
          code: :warn_return_no_exit
        }
      ],
      ignored: [:ignored],
      ignore_path: config.ignore_file
    }
  end
end

defmodule Assay.DaemonRaisingRunner do
  @moduledoc false

  def analyze(_config, _opts) do
    raise "intentional failure"
  end
end

defmodule Assay.DaemonOddIgnoreRunner do
  @moduledoc false

  def analyze(_config, _opts) do
    %{
      status: :ok,
      warnings: [],
      ignored: [],
      ignore_path: 123
    }
  end
end

defmodule Assay.DaemonTest do
  use ExUnit.Case, async: false

  alias Assay.{Config, Daemon}

  @project_root Path.expand("tmp/daemon_project")

  defp base_config do
    %Config{
      apps: [:assay],
      warning_apps: [:assay],
      project_root: @project_root,
      cache_dir: Path.join(@project_root, "_build/assay"),
      plt_path: Path.join(@project_root, "assay.plt"),
      build_lib_path: Path.join(@project_root, "_build"),
      elixir_lib_path: :code.lib_dir(:elixir) |> to_string(),
      ignore_file: Path.join(@project_root, "dialyzer_ignore.exs")
    }
  end

  describe "handle_rpc/2" do
    setup do
      Process.put(:assay_daemon_test_pid, self())
      on_exit(fn -> Process.delete(:assay_daemon_test_pid) end)
      :ok
    end

    test "runs analysis and normalizes request formats" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request = %{
        "id" => 1,
        "method" => "assay/analyze",
        "params" => %{"formats" => ["json", :llm, 123]}
      }

      {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

      assert %{"result" => result} = reply
      assert result["status"] == "ok"
      assert result["ignored"] == 1
      assert result["ignore_file"] == "dialyzer_ignore.exs"
      assert new_state.status == :idle
      assert new_state.last_result == result
      assert_received {:formats, [:json, :llm, :text]}
    end

    test "defaults formats when params are not a list" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request = %{"id" => 9, "method" => "assay/analyze", "params" => %{"formats" => "json"}}
      {reply, _state, :continue} = Daemon.handle_rpc(request, state)

      assert reply["result"]["status"] == "ok"
      assert_received {:formats, [:text]}
    end

    test "reports current status and config" do
      custom_config = %Config{base_config() | apps: [~c"demo", :assay], warning_apps: [~c"demo"]}
      state = Daemon.new(config: custom_config, runner: Assay.DaemonTestRunner)

      request = %{"method" => "assay/getStatus", "id" => 2}
      {reply, _state, :continue} = Daemon.handle_rpc(request, state)
      assert reply["result"]["state"] == "idle"

      request = %{"method" => "assay/getConfig", "id" => 3}
      {reply, _state, :continue} = Daemon.handle_rpc(request, state)
      assert reply["result"]["config"]["apps"] == ["demo", "assay"]
      assert reply["result"]["config"]["warning_apps"] == ["demo"]
      assert reply["result"]["config"]["cache_dir"] == custom_config.cache_dir
      assert reply["result"]["overrides"] == %{}
    end

    test "applies overrides and rejects unknown keys" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request =
        %{
          "method" => "assay/setConfig",
          "id" => 4,
          "params" => %{
            "config" => %{
              "apps" => ["foo"],
              "cache_dir" => "/tmp/new_cache"
            }
          }
        }

      {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

      assert reply["result"]["config"]["apps"] == ["foo"]
      assert new_state.config.apps == [:foo]
      assert new_state.config.cache_dir == "/tmp/new_cache"
      assert new_state.overrides == %{apps: [:foo], cache_dir: "/tmp/new_cache"}

      request = %{
        "method" => "assay/setConfig",
        "id" => 5,
        "params" => %{"config" => %{"bad" => "value"}}
      }

      {reply, _state, :continue} = Daemon.handle_rpc(request, state)
      assert reply["error"]["code"] == -32_602
      assert reply["error"]["message"] =~ "Unsupported override key"
    end

    test "rejects setConfig when config is not a map" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request = %{"method" => "assay/setConfig", "id" => 10, "params" => %{"config" => "bad"}}
      {reply, _state, :continue} = Daemon.handle_rpc(request, state)
      assert reply["error"]["message"] =~ "Unknown method assay/setConfig"
    end

    test "returns error for unknown methods" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)
      {reply, _state, :continue} = Daemon.handle_rpc(%{"method" => "unknown", "id" => 6}, state)
      assert reply["error"]["message"] =~ "Unknown method"
    end

    test "ignores notifications without ids" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)
      {reply, _state, :continue} = Daemon.handle_rpc(%{"method" => "assay/getStatus"}, state)
      assert reply == nil
    end

    test "accepts atom override keys and charlist values" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request =
        %{
          "method" => "assay/setConfig",
          "id" => 8,
          "params" => %{
            "config" => %{
              apps: [:foo],
              cache_dir: ~c"/tmp/assay-cache"
            }
          }
        }

      {reply, new_state, :continue} = Daemon.handle_rpc(request, state)

      assert reply["result"]["config"]["cache_dir"] == "/tmp/assay-cache"
      assert new_state.config.cache_dir == "/tmp/assay-cache"
      assert new_state.config.apps == [:foo]
    end

    test "handles analysis failures" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonRaisingRunner)

      request = %{"id" => 7, "method" => "assay/analyze", "params" => %{}}
      {reply, _state, :continue} = Daemon.handle_rpc(request, state)

      assert reply["error"]["code"] == -32_000
      assert reply["error"]["message"] =~ "intentional failure"
    end

    test "ignores non-request payloads" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)
      {reply, new_state, :continue} = Daemon.handle_rpc("bad", state)
      assert reply == nil
      assert new_state == state
    end

    test "returns overrides payload for getConfig after updates" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request =
        %{
          "method" => "assay/setConfig",
          "id" => 11,
          "params" => %{
            "config" => %{
              "warning_apps" => [~c"demo"],
              "cache_dir" => 123
            }
          }
        }

      {_reply, updated, :continue} = Daemon.handle_rpc(request, state)

      {reply, _state, :continue} =
        Daemon.handle_rpc(%{"method" => "assay/getConfig", "id" => 12}, updated)

      assert reply["result"]["overrides"] == %{
               "warning_apps" => ["demo"],
               "cache_dir" => "123"
             }
    end

    test "passes through ignore_path when it cannot be relativized" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonOddIgnoreRunner)

      request = %{"id" => 13, "method" => "assay/analyze", "params" => %{}}
      {reply, _state, :continue} = Daemon.handle_rpc(request, state)

      assert reply["result"]["ignore_file"] == 123
    end

    test "shutdown requests stop action" do
      state = Daemon.new(config: base_config(), runner: Assay.DaemonTestRunner)

      request = %{"id" => 14, "method" => "assay/shutdown"}
      {reply, _state, :stop} = Daemon.handle_rpc(request, state)

      assert reply["result"]["status"] == "shutting_down"
    end
  end
end
