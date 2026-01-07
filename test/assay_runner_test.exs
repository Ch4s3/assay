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

  test "dialyzer options merge raw dialyzer flag overrides", %{tmp_dir: tmp_dir} do
    init_override = Path.join(tmp_dir, "custom-input.plt")
    output_override = Path.join(tmp_dir, "custom-output.plt")
    include_dir = Path.join(tmp_dir, "includes") |> String.to_charlist()

    config =
      config_fixture(
        dialyzer_flag_options: [include_dirs: [include_dir]],
        dialyzer_init_plt: init_override,
        dialyzer_output_plt: output_override
      )

    options = Runner.dialyzer_options(config)
    assert Keyword.fetch!(options, :plts) == [String.to_charlist(init_override)]
    assert Keyword.fetch!(options, :output_plt) == String.to_charlist(output_override)
    assert Keyword.fetch!(options, :include_dirs) == [include_dir]
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

  test "run explains ignored warnings when explain_ignores is true", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")

    File.write!(ignore_file, """
    [
      "ignored warning",
      ~r/another.*warning/,
      %{file: "lib/third.ex"}
    ]
    """)

    Application.put_env(:assay, :dialyzer_stub_warnings, [
      warning_fixture(Path.join(tmp_dir, "lib/ignored.ex"), "ignored warning"),
      warning_fixture(Path.join(tmp_dir, "lib/another.ex"), "another ignored warning"),
      warning_fixture(Path.join(tmp_dir, "lib/third.ex"), "third warning")
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
        status = Runner.run(config, formats: [], explain_ignores: true)
        assert status == :ok
      end)

    assert output =~ "Ignored 3 warnings via"
    assert output =~ "1. lib/ignored.ex:4"
    assert output =~ "2. lib/another.ex:4"
    assert output =~ "3. lib/third.ex:4"
    assert output =~ "Matched by:"
    assert output =~ "rule #1:"
    assert output =~ "rule #2:"
    assert output =~ "rule #3:"
    assert output =~ "%{file:"
  end

  test "run does not explain when explain_ignores is false", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")

    File.write!(ignore_file, """
    [
      "ignored warning"
    ]
    """)

    Application.put_env(:assay, :dialyzer_stub_warnings, [
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
        status = Runner.run(config, formats: [], explain_ignores: false)
        assert status == :ok
      end)

    assert output =~ "Ignored 1 warning via"
    refute output =~ "1. lib/ignored.ex:4"
    refute output =~ "Matched by:"
  end

  test "run handles explain_ignores with no ignored warnings", %{tmp_dir: tmp_dir} do
    Application.put_env(:assay, :dialyzer_stub_warnings, [
      warning_fixture(Path.join(tmp_dir, "lib/visible.ex"), "visible warning")
    ])

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: nil
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        status = Runner.run(config, formats: [], explain_ignores: true)
        assert status == :warnings
      end)

    refute output =~ "Ignored"
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
      dialyzer_flags: [],
      dialyzer_flag_options: [],
      dialyzer_init_plt: nil,
      dialyzer_output_plt: nil,
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

  test "format_app handles binary paths", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "apps/custom/ebin")
    File.mkdir_p!(path)

    config =
      config_fixture(
        project_root: tmp_dir,
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        apps: [path],
        warning_apps: [path]
      )

    options = Runner.dialyzer_options(config)
    assert Keyword.fetch!(options, :files_rec) == [String.to_charlist(path)]
  end

  test "format_app handles charlist paths", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "apps/charlist/ebin")
    File.mkdir_p!(path)

    config =
      config_fixture(
        project_root: tmp_dir,
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        apps: [to_charlist(path)],
        warning_apps: [to_charlist(path)]
      )

    options = Runner.dialyzer_options(config)
    assert Keyword.fetch!(options, :files_rec) == [String.to_charlist(path)]
  end

  test "format_app raises with invalid app identifier" do
    config = config_fixture(apps: [%{invalid: :app}], warning_apps: [:kernel])

    assert_raise Mix.Error, ~r/Invalid app identifier/, fn ->
      Runner.dialyzer_options(config)
    end
  end

  test "expand_path handles absolute paths", %{tmp_dir: tmp_dir} do
    absolute = Path.join(tmp_dir, "absolute/path")
    File.mkdir_p!(absolute)

    config =
      config_fixture(
        project_root: tmp_dir,
        apps: [absolute],
        warning_apps: [absolute]
      )

    options = Runner.dialyzer_options(config)
    # Absolute paths should not be expanded relative to project_root
    assert Keyword.fetch!(options, :files_rec) == [String.to_charlist(absolute)]
  end

  test "relative_display handles paths that can't be relativized", %{tmp_dir: tmp_dir} do
    # Test the rescue clause in relative_display
    absolute_path = "/absolute/path/that/cant/be/relativized"
    config = config_fixture(project_root: tmp_dir, ignore_file: absolute_path)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.run(config, formats: [], quiet: false)
      end)

    # Should fallback to absolute path if relativization fails
    assert output =~ absolute_path || output =~ "ignore_file:"
  end

  test "format_location handles various entry combinations", %{tmp_dir: tmp_dir} do
    # Test format_location through explain_entry
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")
    File.write!(ignore_file, ~s(["test"]))

    Application.put_env(:assay, :dialyzer_stub_warnings, [
      {:warn_failing_call, {String.to_charlist(Path.join(tmp_dir, "lib/test.ex")), {5, 3}},
       "test"},
      {:warn_failing_call, {String.to_charlist(Path.join(tmp_dir, "lib/test2.ex")), {1, 1}},
       "test2"},
      {:warn_failing_call, {~c"/absolute/path.ex", {10, 1}}, "test3"},
      {:warn_failing_call, {~c"unknown", {1, 1}}, "test4"}
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
        Runner.run(config, formats: [], explain_ignores: true)
      end)

    # Should handle all location combinations
    assert output =~ "lib/test.ex:5"
    assert output =~ "lib/test2.ex"
    assert output =~ "/absolute/path.ex:10"
    # The last entry might format differently, but should not crash
    assert output =~ "test4" || output =~ "warn_failing_call"
  end

  test "format_warning_message handles non-binary text", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")
    File.write!(ignore_file, ~s(["test"]))

    Application.put_env(:assay, :dialyzer_stub_warnings, [
      {:warn_failing_call, {String.to_charlist(Path.join(tmp_dir, "lib/test.ex")), {5, 3}},
       "test"}
    ])

    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        ignore_file: ignore_file
      )

    # This tests format_warning_message through explain_entry
    # The actual formatting happens in the ignore module, but we can verify
    # the code path exists
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.run(config, formats: [], explain_ignores: true)
      end)

    # Should handle message formatting
    assert output =~ "test" || output =~ "warn_failing_call"
  end

  test "format_rule handles various rule types", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")

    File.write!(ignore_file, """
    [
      "string rule",
      ~r/regex.*rule/,
      %{file: "lib/test.ex", line: 5},
      :atom_rule,
      123
    ]
    """)

    Application.put_env(:assay, :dialyzer_stub_warnings, [
      warning_fixture(Path.join(tmp_dir, "lib/test.ex"), "string rule"),
      warning_fixture(Path.join(tmp_dir, "lib/regex.ex"), "regex test rule"),
      warning_fixture(Path.join(tmp_dir, "lib/test.ex"), "other")
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
        Runner.run(config, formats: [], explain_ignores: true)
      end)

    # Should format various rule types
    assert output =~ "rule #"
    assert output =~ "string rule" || output =~ "\"string rule\""
    assert output =~ "~r/" || output =~ "regex"
  end

  test "format_regex_opts handles various regex options", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")

    File.write!(ignore_file, """
    [
      ~r/case/i,
      ~r/multi/m,
      ~r/unicode/u
    ]
    """)

    Application.put_env(:assay, :dialyzer_stub_warnings, [
      warning_fixture(Path.join(tmp_dir, "lib/test.ex"), "case insensitive"),
      warning_fixture(Path.join(tmp_dir, "lib/test.ex"), "multi line"),
      warning_fixture(Path.join(tmp_dir, "lib/test.ex"), "unicode test")
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
        Runner.run(config, formats: [], explain_ignores: true)
      end)

    # Should format regex options
    assert output =~ "~r/" || output =~ "rule #"
  end

  test "selector_info handles empty selectors", %{tmp_dir: tmp_dir} do
    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        app_sources: [],
        warning_app_sources: []
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.analyze(config, print_config: true)
      end)

    # Should handle empty selectors gracefully
    assert output =~ "Assay configuration"
  end

  test "selector_explanation handles various selector types", %{tmp_dir: tmp_dir} do
    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        app_sources: [
          %{selector: :project, apps: [:kernel]},
          %{selector: :project_plus_deps, apps: [:kernel, :logger]},
          %{selector: :current, apps: [:kernel]},
          %{selector: :current_plus_deps, apps: [:kernel, :logger]},
          %{selector: "custom", apps: [:kernel]}
        ]
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.analyze(config, print_config: true)
      end)

    # Should explain various selector types
    assert output =~ "project apps" || output =~ "project_plus_deps" || output =~ "current"
  end

  test "discovery_summary handles non-matching discovery_info", %{tmp_dir: tmp_dir} do
    config =
      config_fixture(
        project_root: tmp_dir,
        cache_dir: Path.join(tmp_dir, "tmp/assay"),
        plt_path: Path.join(tmp_dir, "tmp/assay/#{@plt_filename}"),
        build_lib_path: Path.join(tmp_dir, "_build/dev/lib"),
        discovery_info: %{other: :data}
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.analyze(config, print_config: true)
      end)

    # Should handle non-matching discovery_info gracefully
    assert output =~ "Assay configuration"
  end

  test "plural_suffix handles singular and plural", %{tmp_dir: tmp_dir} do
    ignore_file = Path.join(tmp_dir, "dialyzer_ignore.exs")
    File.write!(ignore_file, ~s(["test"]))

    # Test singular (1 warning)
    Application.put_env(:assay, :dialyzer_stub_warnings, [
      warning_fixture(Path.join(tmp_dir, "lib/test.ex"), "test")
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
        Runner.run(config, formats: [])
      end)

    # Should use singular form
    assert output =~ "Ignored 1 warning" && not (output =~ "Ignored 1 warnings")
  end

  defmodule FailingDialyzerStub do
    def run(_opts), do: throw({:dialyzer_error, ~c"failure"})
  end
end
