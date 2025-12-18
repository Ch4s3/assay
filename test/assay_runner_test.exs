defmodule Assay.RunnerTest do
  use ExUnit.Case, async: true

  alias Assay.Config
  alias Assay.Runner

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
  end

  defp config_fixture(attrs \\ []) do
    project_root = File.cwd!()

    base = %Config{
      apps: [:kernel],
      warning_apps: [:kernel],
      project_root: project_root,
      cache_dir: Path.join(project_root, "tmp/assay"),
      plt_path: Path.join(project_root, "tmp/assay/assay.incremental.plt"),
      build_lib_path: Path.join(project_root, "_build/dev/lib"),
      elixir_lib_path: :code.lib_dir(:elixir) |> to_string(),
      ignore_file: nil
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
end
