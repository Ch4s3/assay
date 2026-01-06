defmodule Assay.DialyzerFlagsTest do
  use ExUnit.Case, async: true

  alias Assay.DialyzerFlags

  @project_root Path.expand("tmp/dialyzer_flags_project")

  describe "parse/3" do
    test "collects error_location and warning flags" do
      result =
        DialyzerFlags.parse(
          ["--error_location column", "-Wunmatched_return"],
          :cli,
          @project_root
        )

      assert {:error_location, :column} in result.options
      assert {:warnings, [:unmatched_return]} in result.options
    end

    test "captures solver selection and defines" do
      result =
        DialyzerFlags.parse(
          ["--solver v2", "-DDEBUG=1"],
          :config,
          @project_root
        )

      assert {:solvers, [:v2]} in result.options
      assert {:defines, [{:DEBUG, 1}]} in result.options
    end

    test "returns expanded PLT paths" do
      result =
        DialyzerFlags.parse(
          ["--output_plt tmp/out.plt", "--plt tmp/init.plt"],
          :config,
          @project_root
        )

      assert result.output_plt == Path.expand("tmp/out.plt", @project_root) |> to_charlist()
      assert result.init_plt == Path.expand("tmp/init.plt", @project_root) |> to_charlist()
    end
  end

  describe "parse/3 additional flag handling" do
    test "includes include directories and warning flags" do
      opts =
        DialyzerFlags.parse(
          ["-Ilib", "--include=src", "-Wunmatched_return"],
          :cli,
          @project_root
        )

      include_dirs =
        opts.options
        |> Enum.filter(fn {key, _value} -> key == :include_dirs end)
        |> Enum.map(&elem(&1, 1))

      expanded_lib = Path.expand("lib", @project_root) |> to_charlist()
      expanded_src = Path.expand("src", @project_root) |> to_charlist()

      assert Enum.any?(include_dirs, fn list -> expanded_lib in list end)
      assert Enum.any?(include_dirs, fn list -> expanded_src in list end)
      assert {:warnings, [:unmatched_return]} in opts.options
    end

    test "parses defines without explicit value" do
      opts =
        DialyzerFlags.parse(
          ["-DDEBUG"],
          :config,
          @project_root
        )

      assert {:defines, [{:DEBUG, true}]} in opts.options
    end

    test "raises on disallowed flag" do
      assert_raise Mix.Error, fn ->
        DialyzerFlags.parse(["--add_to_plt"], :config, @project_root)
      end
    end

    test "raises on invalid define term" do
      assert_raise Mix.Error, fn ->
        DialyzerFlags.parse(["-DINVALID=foo("], :cli, @project_root)
      end
    end

    test "parses no-arg flags and inline args" do
      opts =
        DialyzerFlags.parse(
          ["--raw", "--fullpath", "--no_indentation", "--no_spec", "--error_location=column"],
          :cli,
          @project_root
        )

      assert {:output_format, :raw} in opts.options
      assert {:filename_opt, :fullpath} in opts.options
      assert {:indent_opt, false} in opts.options
      assert {:use_contracts, false} in opts.options
      assert {:error_location, :column} in opts.options
    end

    test "parses long-form define/include flags" do
      opts =
        DialyzerFlags.parse(
          ["--define TEST=2", "--include lib"],
          :config,
          @project_root
        )

      assert {:defines, [{:TEST, 2}]} in opts.options
      assert {:include_dirs, [Path.expand("lib", @project_root) |> to_charlist()]} in opts.options
    end

    test "parses output graph and metrics flags" do
      opts =
        DialyzerFlags.parse(
          [
            "--dump_callgraph tmp/call.graph",
            "--dump_full_dependencies_graph tmp/deps.graph",
            "--metrics_file tmp/metrics.out",
            "--module_lookup_file tmp/lookup.out",
            "--solver=v1"
          ],
          :cli,
          @project_root
        )

      assert {:callgraph_file, Path.expand("tmp/call.graph", @project_root) |> to_charlist()} in opts.options
      assert {:mod_deps_file, Path.expand("tmp/deps.graph", @project_root) |> to_charlist()} in opts.options
      assert {:metrics_file, Path.expand("tmp/metrics.out", @project_root) |> to_charlist()} in opts.options
      assert {:module_lookup_file, Path.expand("tmp/lookup.out", @project_root) |> to_charlist()} in opts.options
      assert {:solvers, [:v1]} in opts.options
    end

    test "accepts keyword option entries" do
      opts = DialyzerFlags.parse([warnings: [:unknown]], :config, @project_root)
      assert {:warnings, [:unknown]} in opts.options
    end

    test "rejects unsupported option keys" do
      assert_raise Mix.Error, fn ->
        DialyzerFlags.parse([bad_option: true], :config, @project_root)
      end
    end

    test "raises when a flag is missing its argument" do
      assert_raise Mix.Error, fn ->
        DialyzerFlags.parse(["--solver"], :cli, @project_root)
      end
    end

    test "raises on invalid error_location values" do
      assert_raise Mix.Error, fn ->
        DialyzerFlags.parse(["--error_location bad"], :cli, @project_root)
      end
    end

    test "raises on unsupported solver values" do
      assert_raise Mix.Error, fn ->
        DialyzerFlags.parse(["--solver v3"], :cli, @project_root)
      end
    end

    test "accepts charlist entries for flags" do
      opts = DialyzerFlags.parse([~c"--statistics"], :config, @project_root)
      assert {:timing, true} in opts.options
    end

    test "accepts tuple flag entries with binary keys" do
      opts = DialyzerFlags.parse([{"--solver", "v1"}], :config, @project_root)
      assert {:solvers, [:v1]} in opts.options
    end
  end
end
