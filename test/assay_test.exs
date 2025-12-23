defmodule AssayTest do
  use ExUnit.Case, async: true

  alias Assay.TestSupport.{ConfigStub, RunnerStub}

  setup do
    Application.put_env(:assay, :config_module, ConfigStub)
    Application.put_env(:assay, :runner_module, RunnerStub)

    on_exit(fn ->
      Application.delete_env(:assay, :config_module)
      Application.delete_env(:assay, :runner_module)
    end)

    :ok
  end

  test "run builds config from project options and delegates to runner" do
    Process.put(:runner_stub_status, :warnings)
    opts = [project_root: "/tmp/project", print_config: true]

    assert Assay.run(opts) == :warnings
    assert_received {:config_opts, ^opts}

    assert_received {:runner_called, config, ^opts}
    assert config.project_root == "/tmp/project"
    assert config.cache_dir == Path.join("/tmp/project", "_build/assay")
  end

  test "run uses default options when none supplied" do
    Process.put(:runner_stub_status, :ok)

    assert Assay.run() == :ok
    assert_received {:config_opts, []}
    assert_received {:runner_called, %Assay.Config{}, []}
  end
end
