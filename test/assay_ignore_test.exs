defmodule Assay.IgnoreTest do
  use ExUnit.Case, async: false

  alias Assay.Ignore

  setup do
    original_module = Application.get_env(:assay, :dialyzer_module)
    original_text = Application.get_env(:assay, :dialyzer_warning_text)

    Application.put_env(:assay, :dialyzer_module, Assay.IgnoreTestDialyzer)

    on_exit(fn ->
      reset_env(:dialyzer_module, original_module)
      reset_env(:dialyzer_warning_text, original_text)
    end)

    :ok
  end

  defp reset_env(key, nil), do: Application.delete_env(:assay, key)
  defp reset_env(key, value), do: Application.put_env(:assay, key, value)

  describe "decorate/2" do
    test "builds entries with normalized paths" do
      project_root = Path.expand("tmp/ignore_project")
      warning_text = "#{project_root}/lib/sample.ex:3: warning"

      Application.put_env(:assay, :dialyzer_warning_text, warning_text)

      [entry] =
        Ignore.decorate(
          [{:warn_return_no_exit, {"lib/sample.ex", {3, 4}}, "details"}],
          project_root
        )

      assert entry.relative_path == "lib/sample.ex"
      assert entry.path == Path.join(project_root, "lib/sample.ex")
      assert entry.line == 3
      assert entry.match_text == warning_text
      assert entry.text == "lib/sample.ex:3: warning"
    end
  end

  describe "filter/2" do
    setup do
      entry = %{
        match_text: "lib/sample.ex:3: a warning",
        path: "lib/sample.ex",
        relative_path: "lib/sample.ex",
        line: 3,
        column: 2,
        code: :warn_return_no_exit
      }

      {:ok, entry: entry}
    end

    test "returns inputs when ignore rules are disabled", %{entry: entry} do
      result = Ignore.filter([entry], nil)
      assert result == {[entry], [], nil}
    end

    test "returns inputs when ignore file is missing", %{entry: entry} do
      missing = Path.join(System.tmp_dir!(), "assay-ignore-missing.exs")
      File.rm_rf!(missing)

      result = Ignore.filter([entry], missing)
      assert result == {[entry], [], nil}
    end

    test "applies ignore rules from file", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))
      File.write!(ignore_file, ~S(["lib/sample.ex"]))

      {kept, ignored, path} = Ignore.filter([entry], ignore_file)

      assert path == ignore_file
      assert kept == []
      assert ignored == [entry]
    end
  end
end

defmodule Assay.IgnoreTestDialyzer do
  @moduledoc false

  def format_warning(_warning, _opts) do
    Application.get_env(:assay, :dialyzer_warning_text, "dialyzer warning")
  end
end
