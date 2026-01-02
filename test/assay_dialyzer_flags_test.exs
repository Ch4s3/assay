defmodule Assay.DialyzerFlagsTest do
  use ExUnit.Case, async: true

  alias Assay.DialyzerFlags

  @tmp_root File.cwd!()

  test "parses simple flags and options" do
    result =
      DialyzerFlags.parse(
        ["--statistics", {"--output_plt", "tmp/plt/custom.plt"}],
        :config,
        @tmp_root
      )

    assert result.options == [timing: true]

    assert result.output_plt ==
             Path.expand("tmp/plt/custom.plt", @tmp_root) |> String.to_charlist()

    assert result.init_plt == nil
  end

  test "supports warning and define flags" do
    flag =
      DialyzerFlags.parse(
        ["-Wunderspecs", {"-D", "FEATURE=true"}],
        :cli,
        @tmp_root
      )

    assert flag.options == [warnings: [:underspecs], defines: [{:FEATURE, true}]]
  end

  test "parses include paths and module lookup files" do
    result =
      DialyzerFlags.parse(
        ["--include=lib", {"--module_lookup_file", "tmp/lookup.dat"}],
        :config,
        @tmp_root
      )

    include_dir = Path.expand("lib", @tmp_root) |> String.to_charlist()
    lookup = Path.expand("tmp/lookup.dat", @tmp_root) |> String.to_charlist()

    assert Keyword.fetch!(result.options, :include_dirs) == [include_dir]
    assert Keyword.fetch!(result.options, :module_lookup_file) == lookup
  end

  test "captures init plt overrides" do
    result =
      DialyzerFlags.parse(
        [{"--plt", "tmp/plts/base.plt"}],
        :cli,
        @tmp_root
      )

    assert result.init_plt == Path.expand("tmp/plts/base.plt", @tmp_root) |> String.to_charlist()
  end

  test "supports metrics and solver flags within nested lists" do
    result =
      DialyzerFlags.parse(
        [[{"--metrics_file", "tmp/metrics.txt"}, "--solver=v1"]],
        :config,
        @tmp_root
      )

    metrics = Path.expand("tmp/metrics.txt", @tmp_root) |> String.to_charlist()
    assert Keyword.fetch!(result.options, :metrics_file) == metrics
    assert Keyword.fetch!(result.options, :solvers) == [:v1]
  end

  test "rejects disallowed flags" do
    assert_raise Mix.Error, fn ->
      DialyzerFlags.parse(["--build_plt"], :cli, @tmp_root)
    end
  end

  test "parses chained raw flag string" do
    result =
      DialyzerFlags.parse(
        "--resources --raw --no_indentation --no_spec --error_location=column",
        :cli,
        @tmp_root
      )

    assert Keyword.fetch!(result.options, :report_mode) == :quiet
    assert Keyword.fetch!(result.options, :timing) == :debug
    assert Keyword.fetch!(result.options, :output_format) == :raw
    assert Keyword.fetch!(result.options, :indent_opt) == false
    assert Keyword.fetch!(result.options, :use_contracts) == false
    assert Keyword.fetch!(result.options, :error_location) == :column
  end

  test "accepts keyword style include_dirs" do
    result = DialyzerFlags.parse([include_dirs: [~c"char/include"]], :config, @tmp_root)
    assert Keyword.fetch!(result.options, :include_dirs) == [~c"char/include"]
  end

  test "parse errors when error_location invalid" do
    assert_raise Mix.Error, fn ->
      DialyzerFlags.parse(["--error_location=bogus"], :cli, @tmp_root)
    end
  end

  test "parse errors when solver unknown" do
    assert_raise Mix.Error, fn ->
      DialyzerFlags.parse(["--solver=unknown"], :cli, @tmp_root)
    end
  end

  test "parse errors for unsupported flags" do
    assert_raise Mix.Error, fn ->
      DialyzerFlags.parse(["--totally-unknown"], :config, @tmp_root)
    end
  end

  test "parse errors for invalid define value" do
    assert_raise Mix.Error, fn ->
      DialyzerFlags.parse([{"--define", "="}], :config, @tmp_root)
    end
  end
end
