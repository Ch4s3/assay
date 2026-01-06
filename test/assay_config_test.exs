defmodule Assay.ConfigTest do
  use ExUnit.Case, async: false

  alias Assay.Config

  test "from_mix_project resolves selectors and options" do
    with_project(
      [
        apps: [:project],
        warning_apps: [:current_plus_deps],
        warnings: [:unmatched_return],
        ignore_file: nil,
        dialyzer_flags: ["--statistics"]
      ],
      fn project_app, _project_dir ->
        config = Config.from_mix_project(dependency_apps: [:dep_one])

        assert project_app in config.apps
        assert :dep_one in config.warning_apps
        assert config.ignore_file == nil
        assert config.warnings == [:unmatched_return]
        assert "--statistics" in config.dialyzer_flags
        assert {:timing, true} in config.dialyzer_flag_options

        assert Enum.any?(config.app_sources, &match?(%{selector: :project}, &1))
        assert Enum.any?(config.warning_app_sources, &match?(%{selector: :current_plus_deps}, &1))

        optional_apps = optional_apps()
        assert Enum.all?(optional_apps, &(&1 in config.apps))
      end
    )
  end

  test "from_mix_project keeps literal app values with paths" do
    with_project([apps: [:project], warning_apps: [:project]], fn project_app, _project_dir ->
      config =
        Config.from_mix_project(
          apps: ["apps/demo"],
          warning_apps: [:project]
        )

      assert "apps/demo" in config.apps
      assert project_app in config.warning_apps
    end)
  end

  test "from_mix_project expands project+deps selector" do
    with_project([apps: ["project+deps"], warning_apps: ["current"]], fn project_app, _project_dir ->
      config = Config.from_mix_project(dependency_apps: [:dep_one])

      assert project_app in config.apps
      assert :dep_one in config.apps
      assert :logger in config.apps
      assert config.warning_apps == [project_app]
    end)
  end

  test "from_mix_project normalizes charlist app overrides" do
    with_project([apps: [:project], warning_apps: [:project]], fn _project_app, _project_dir ->
      config =
        Config.from_mix_project(
          apps: ~c"custom_app",
          warning_apps: ~c"custom_app"
        )

      chars = Enum.uniq(~c"custom_app")
      assert Enum.all?(chars, &(&1 in config.apps))
      assert Enum.all?(chars, &(&1 in config.warning_apps))
    end)
  end

  test "from_mix_project expands ignore_file paths" do
    with_project([apps: [:project], warning_apps: [:project], ignore_file: "ignore.exs"], fn _app, _project_dir ->
      config = Config.from_mix_project()
      assert String.ends_with?(config.ignore_file, "/ignore.exs")
    end)
  end

  test "from_mix_project raises when warnings are not a list" do
    assert_raise Mix.Error, fn ->
      with_project([apps: [:project], warning_apps: [:project], warnings: "bad"], fn _app, _dir ->
        Config.from_mix_project()
      end)
    end
  end

  test "from_mix_project normalizes ignore_file and merges CLI flags" do
    with_project(
      [
        apps: [:project],
        warning_apps: [:project],
        ignore_file: false,
        dialyzer_flags: ["--output_plt tmp/config.plt"]
      ],
      fn _app, _dir ->
        config =
          Config.from_mix_project(
            dialyzer_flags: ["--plt tmp/init.plt", "--output_plt tmp/cli.plt"]
          )

        assert config.ignore_file == nil
        assert "--output_plt tmp/config.plt" in config.dialyzer_flags
        assert "--plt tmp/init.plt" in config.dialyzer_flags
        assert "--output_plt tmp/cli.plt" in config.dialyzer_flags

        assert config.dialyzer_init_plt == Path.expand("tmp/init.plt") |> to_charlist()
        assert config.dialyzer_output_plt == Path.expand("tmp/cli.plt") |> to_charlist()
      end
    )
  end

  test "from_mix_project raises when apps are not a list" do
    assert_raise Mix.Error, fn ->
      with_project([apps: "bad", warning_apps: [:project]], fn _app, _dir ->
        Config.from_mix_project()
      end)
    end
  end

  defp with_project(dialyzer_config, fun) when is_function(fun, 2) do
    token = System.unique_integer([:positive])
    project_app = :"assay_config_#{token}"
    project_module = Module.concat([Assay.ConfigTestProject, :"Project#{token}"])

    project_dir = Path.join(System.tmp_dir!(), "assay_config_#{token}")
    File.rm_rf!(project_dir)
    File.mkdir_p!(project_dir)

    mix_exs_content = """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [
          app: #{inspect(project_app)},
          version: "0.1.0",
          deps: [],
          assay: [
            dialyzer: #{inspect(dialyzer_config)}
          ]
        ]
      end

      def application, do: []
    end
    """

    File.write!(Path.join(project_dir, "mix.exs"), mix_exs_content)

    try do
      Mix.Project.in_project(project_app, project_dir, fn _ -> fun.(project_app, project_dir) end)
    after
      File.rm_rf!(project_dir)
    end
  end

  defp optional_apps do
    [
      {:erlex, :"Elixir.Erlex"},
      {:igniter, :"Elixir.Igniter"},
      {:rewrite, :"Elixir.Rewrite.Source"}
    ]
    |> Enum.filter(fn {_app, mod} -> Code.ensure_loaded?(mod) end)
    |> Enum.map(&elem(&1, 0))
  end
end
