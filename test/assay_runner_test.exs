defmodule Assay.RunnerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Assay.Config
  alias Assay.Runner

  @plt_filename Assay.Config.plt_filename()

  setup do
    Application.put_env(:assay, :dialyzer_module, __MODULE__.DialyzerFormatStub)
    Application.put_env(:assay, :dialyzer_runner_module, __MODULE__.DialyzerStub)

    on_exit(fn ->
      Application.delete_env(:assay, :dialyzer_module)
      Application.delete_env(:assay, :dialyzer_runner_module)
      Application.delete_env(:assay, :dialyzer_stub_warnings)
    end)

    :ok
  end

  test "dialyzer options enable incremental mode and reuse the configured PLT" do
    config = config_fixture()

    options = Runner.dialyzer_options(config)

    assert {:analysis_type, :incremental} in options
    assert {:check_plt, false} in options

    plt = to_charlist(config.plt_path)
    assert Keyword.fetch!(options, :plts) == [plt]
    assert Keyword.fetch!(options, :output_plt) == plt
    assert {:from, :byte_code} in options
    assert {:get_warnings, true} in options

    files_rec = Keyword.fetch!(options, :files_rec)
    warning_files_rec = Keyword.fetch!(options, :warning_files_rec)
    expected_path = expected_kernel_ebin()

    assert files_rec == [expected_path]
    assert warning_files_rec == [expected_path]
    refute Keyword.has_key?(options, :warnings)
  end

  test "dialyzer options include warnings when configured" do
    config = config_fixture(warnings: [:overspecs, :underspecs])
    options = Runner.dialyzer_options(config)
    assert Keyword.fetch!(options, :warnings) == [:overspecs, :underspecs]
  end

  test "dialyzer options resolve project apps via build lib path", %{tmp_dir: tmp_dir} do
    build_lib_path = Path.join(tmp_dir, "_build/dev/lib")
    sample_app_ebin = Path.join(build_lib_path, "sample_proj/ebin")
    File.mkdir_p!(sample_app_ebin)

    config =
      config_fixture(
        project_root: tmp_dir,
        build_lib_path: build_lib_path,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        apps: [:sample_proj],
        warning_apps: [:sample_proj]
      )

    options = Runner.dialyzer_options(config)

    assert Keyword.fetch!(options, :files_rec) == [String.to_charlist(sample_app_ebin)]
    assert Keyword.fetch!(options, :warning_files_rec) == [String.to_charlist(sample_app_ebin)]
  end

  test "dialyzer options expand relative string paths", %{tmp_dir: tmp_dir} do
    relative_path = Path.join(["apps", "demo", "ebin"])
    absolute = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(absolute)

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        apps: [relative_path],
        warning_apps: [relative_path]
      )

    options = Runner.dialyzer_options(config)

    assert Keyword.fetch!(options, :files_rec) == [String.to_charlist(absolute)]
    assert Keyword.fetch!(options, :warning_files_rec) == [String.to_charlist(absolute)]
  end

  test "dialyzer options accept charlist paths", %{tmp_dir: tmp_dir} do
    relative_path = Path.join(tmp_dir, "apps/char/ebin")
    File.mkdir_p!(relative_path)

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        apps: [to_charlist("apps/char/ebin")],
        warning_apps: [to_charlist("apps/char/ebin")]
      )

    options = Runner.dialyzer_options(config)
    expected = [String.to_charlist(relative_path)]

    assert Keyword.fetch!(options, :files_rec) == expected
    assert Keyword.fetch!(options, :warning_files_rec) == expected
  end

  test "dialyzer options reject invalid app identifiers" do
    config = config_fixture(apps: [:kernel, %{}])

    assert_raise Mix.Error, fn ->
      Runner.dialyzer_options(config)
    end
  end

  test "dialyzer options error when app ebin is missing", %{tmp_dir: tmp_dir} do
    config =
      config_fixture(
        project_root: tmp_dir,
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/plt"),
        apps: [:missing_app],
        warning_apps: [:missing_app]
      )

    assert_raise Mix.Error, fn ->
      Runner.dialyzer_options(config)
    end
  end

  test "analyze groups warnings and respects ignore file", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")

    File.write!(ignore_file, """
    [
      "ignored warning"
    ]
    """)

    warnings = [
      warning_fixture(Path.join(tmp_dir, "lib/visible.ex"), "visible warning"),
      warning_fixture(Path.join(tmp_dir, "lib/ignored.ex"), "ignored warning")
    ]

    Application.put_env(:assay, :dialyzer_stub_warnings, warnings)

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: ignore_file
      )

    result = Runner.analyze(config)

    assert result.status == :warnings
    assert Enum.map(result.warnings, & &1.match_text) == ["visible warning"]
    assert Enum.map(result.ignored, & &1.match_text) == ["ignored warning"]
    assert result.ignore_path == ignore_file
  end

  test "analyze can print derived configuration", %{tmp_dir: tmp_dir} do
    Application.put_env(:assay, :dialyzer_stub_warnings, [])

    selector_meta = [%{selector: :project_plus_deps, apps: [:kernel]}]

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: Path.join(tmp_dir, "dialyzer_ignore.exs"),
        app_sources: selector_meta,
        warning_app_sources: [%{selector: :project, apps: [:kernel]}]
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.analyze(config, print_config: true)
      end)

    assert output =~ "Assay configuration (from mix.exs)"
    assert output =~ "Effective Dialyzer options:"
    assert output =~ "project apps + dependencies + base OTP libraries"
    assert output =~ "Mix.Project.apps_paths/0"
    refute output =~ ":plts"
    refute output =~ ":output_plt"
    refute output =~ ":files_rec"
    refute output =~ ":warning_files_rec"
  end

  test "analyze raises when dialyzer reports errors", %{tmp_dir: tmp_dir} do
    Application.put_env(:assay, :dialyzer_runner_module, __MODULE__.FailingDialyzerStub)

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: nil
      )

    assert_raise Mix.Error, fn ->
      Runner.analyze(config)
    end
  end

  test "run prints summary, handles ignore descriptions, and logs ignored warnings", %{
    tmp_dir: tmp_dir
  } do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")

    File.write!(ignore_file, """
    [
      "ignored warning"
    ]
    """)

    Application.put_env(:assay, :dialyzer_stub_warnings, [
      warning_fixture(Path.join(tmp_dir, "lib/visible.ex"), "visible warning"),
      warning_fixture(Path.join(tmp_dir, "lib/ignored.ex"), "ignored warning")
    ])

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: ignore_file
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        status = Runner.run(config, formats: [])
        assert status == :warnings
      end)

    assert output =~ "ignore_file: #{Path.relative_to(ignore_file, tmp_dir)}"
    assert output =~ "Ignored 1 warning via #{Path.relative_to(ignore_file, tmp_dir)}"
  end

  test "run reports missing ignore files as part of the summary", %{tmp_dir: tmp_dir} do
    Application.put_env(:assay, :dialyzer_stub_warnings, [])
    missing = Path.join(tmp_dir, "missing_ignore.exs")

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: missing
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        status = Runner.run(config, formats: [])
        assert status == :ok
      end)

    assert output =~ "ignore_file: #{Path.relative_to(missing, tmp_dir)} (missing)"
  end

  test "run toggles ANSI color for elixir format based on MIX_ANSI_ENABLED", %{tmp_dir: tmp_dir} do
    Application.put_env(:assay, :dialyzer_stub_warnings, [])

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: nil
      )

    System.put_env("MIX_ANSI_ENABLED", "false")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Runner.run(config, formats: [:elixir, :text]) == :ok
      end)

    System.delete_env("MIX_ANSI_ENABLED")

    assert output =~ "Assay (incremental dialyzer)"
  end

  defp config_fixture(attrs \\ []) do
    project_root = File.cwd!()

    base = %Config{
      apps: [:kernel],
      warning_apps: [:kernel],
      project_root: project_root,
      cache_dir: Path.join(project_root, "tmp/assay"),
      plt_path: Path.join(project_root, "tmp/assay/#{@plt_filename}"),
      build_lib_path: Path.join(project_root, "_build/dev/lib"),
      elixir_lib_path: :code.lib_dir(:elixir) |> to_string(),
      ignore_file: nil,
      warnings: [],
      app_sources: [],
      warning_app_sources: [],
      discovery_info: %{
        project_apps: [:kernel],
        dependency_apps: [],
        base_apps: [:logger, :kernel, :stdlib, :elixir, :erts]
      }
    }

    base
    |> Map.from_struct()
    |> Map.merge(Map.new(attrs))
    |> then(&struct!(Config, &1))
  end

  defp expected_kernel_ebin do
    :kernel
    |> :code.lib_dir()
    |> IO.chardata_to_string()
    |> Path.join("ebin")
    |> String.to_charlist()
  end

  defp warning_fixture(file, message) do
    location = {String.to_charlist(file), {4, 1}}
    {:warn_failing_call, location, message}
  end

  defmodule DialyzerStub do
    def run(_opts) do
      Application.get_env(:assay, :dialyzer_stub_warnings, [])
    end
  end

  defmodule DialyzerFormatStub do
    def format_warning({_code, _location, message}, _opts) do
      message |> to_string() |> String.to_charlist()
    end
  end

  defmodule FailingDialyzerStub do
    def run(_opts), do: throw({:dialyzer_error, ~c"failure"})
  end
end
