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
end
