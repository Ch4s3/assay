defmodule Assay.ConfigTest do
  use ExUnit.Case, async: false

  alias Assay.Config

  @plt_filename Assay.Config.plt_filename()

  @moduletag :tmp_dir

  setup context do
    project_module = Map.get(context, :project_module, __MODULE__.ValidProject)
    Mix.Project.push(project_module)

    on_exit(fn ->
      Mix.Project.pop()
    end)

    :ok
  end

  test "from_mix_project builds a normalized config struct", %{tmp_dir: tmp_dir} do
    config = Config.from_mix_project(project_root: tmp_dir)

    assert Enum.sort(config.apps) == Enum.sort([:demo, :erlex, :igniter, :rewrite])
    assert config.warning_apps == [:demo_warn]
    assert config.cache_dir == Path.join(tmp_dir, "_build/assay")
    assert config.plt_path == Path.join(tmp_dir, "_build/assay/#{@plt_filename}")
    assert config.elixir_lib_path == :code.lib_dir(:elixir) |> to_string()

    assert config.ignore_file ==
             Path.expand("config/dialyzer_ignore.exs", tmp_dir)

    assert config.warnings == [:error_handling]
  end

  @tag project_module: __MODULE__.NilIgnoreProject
  test "from_mix_project treats nil ignore file as disabled", %{tmp_dir: tmp_dir} do
    config = Config.from_mix_project(project_root: tmp_dir)
    assert config.ignore_file == nil
  end

  @tag project_module: __MODULE__.MissingAppsProject
  test "from_mix_project raises when required lists are missing", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, fn ->
      Config.from_mix_project(project_root: tmp_dir)
    end
  end

  @tag project_module: __MODULE__.InvalidWarningsProject
  test "from_mix_project validates optional warnings as lists", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, fn ->
      Config.from_mix_project(project_root: tmp_dir)
    end
  end

  @tag project_module: __MODULE__.SelectorProject
  test "from_mix_project resolves symbolic selectors", %{tmp_dir: tmp_dir} do
    config =
      Config.from_mix_project(
        project_root: tmp_dir,
        dependency_apps: [:dep_one, :dep_two]
      )

    expected =
      Enum.sort([
        :selector_demo,
        :dep_one,
        :dep_two,
        :logger,
        :kernel,
        :stdlib,
        :elixir,
        :erts,
        :erlex,
        :igniter,
        :rewrite
      ])

    assert Enum.sort(config.apps) == expected

    assert config.warning_apps == [:selector_demo]

    assert [%{selector: :project_plus_deps, apps: apps}] = config.app_sources
    assert :selector_demo in apps
    assert [%{selector: :current, apps: [:selector_demo]}] = config.warning_app_sources
  end

  defmodule ValidProject do
    def project do
      [
        app: :demo,
        version: "0.1.0",
        assay: [
          dialyzer: [
            apps: [:demo],
            warning_apps: [:demo_warn],
            ignore_file: "config/dialyzer_ignore.exs",
            warnings: [:error_handling]
          ]
        ]
      ]
    end

    def application, do: []
  end

  defmodule NilIgnoreProject do
    def project do
      [
        app: :demo,
        version: "0.1.0",
        assay: [
          dialyzer: [
            apps: [:demo],
            warning_apps: [:demo],
            ignore_file: nil
          ]
        ]
      ]
    end

    def application, do: []
  end

  defmodule MissingAppsProject do
    def project do
      [
        app: :demo,
        version: "0.1.0",
        assay: [
          dialyzer: [
            warning_apps: [:demo]
          ]
        ]
      ]
    end

    def application, do: []
  end

  defmodule InvalidWarningsProject do
    def project do
      [
        app: :demo,
        version: "0.1.0",
        assay: [
          dialyzer: [
            apps: [:demo],
            warning_apps: [:demo],
            warnings: :overspecs
          ]
        ]
      ]
    end

    def application, do: []
  end

  defmodule SelectorProject do
    def project do
      [
        app: :selector_demo,
        version: "0.1.0",
        assay: [
          dialyzer: [
            apps: [:project_plus_deps],
            warning_apps: [:current]
          ]
        ]
      ]
    end

    def application, do: []
  end
end
