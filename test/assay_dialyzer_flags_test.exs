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
end
