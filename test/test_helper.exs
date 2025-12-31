ExUnit.start()

defmodule Assay.TestSupport.ConfigStub do
  alias Assay.Config

  def from_mix_project(opts) do
    send(self(), {:config_opts, opts})
    root = Keyword.get(opts, :project_root, "/tmp/assay-test")
    apps = Keyword.get(opts, :apps, [:stub])
    warning_apps = Keyword.get(opts, :warning_apps, apps)
    cache_dir = Path.join(root, "_build/assay")
    plt_filename = Config.plt_filename()

    %Config{
      apps: apps,
      warning_apps: warning_apps,
      project_root: root,
      cache_dir: cache_dir,
      plt_path: Path.join(cache_dir, plt_filename),
      build_lib_path: Path.join(root, "_build/dev/lib"),
      elixir_lib_path: Path.join(root, ".elixir"),
      ignore_file: Path.join(root, "dialyzer_ignore.exs"),
      warnings: Keyword.get(opts, :warnings, []),
      app_sources: Keyword.get(opts, :app_sources, []),
      warning_app_sources: Keyword.get(opts, :warning_app_sources, []),
      dialyzer_flags: Keyword.get(opts, :dialyzer_flags, []),
      dialyzer_flag_options: Keyword.get(opts, :dialyzer_flag_options, []),
      dialyzer_init_plt: Keyword.get(opts, :dialyzer_init_plt),
      dialyzer_output_plt: Keyword.get(opts, :dialyzer_output_plt),
      discovery_info:
        Keyword.get(opts, :discovery_info, %{
          project_apps: apps,
          dependency_apps: [],
          base_apps: []
        })
    }
  end
end

defmodule Assay.TestSupport.RunnerStub do
  def run(config, opts) do
    send(self(), {:runner_called, config, opts})
    Process.get(:runner_stub_status, :ok)
  end
end
