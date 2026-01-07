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

    test "handles metadata in warnings and charlist paths" do
      project_root = Path.expand("tmp/ignore_project_meta")
      warning_text = "#{project_root}/lib/meta.ex:4: warning"

      Application.put_env(:assay, :dialyzer_warning_text, warning_text)

      [entry] =
        Ignore.decorate(
          [{{:warn_return_no_exit, :meta}, {~c"lib/meta.ex", {4, 2, :extra}}, "details"}],
          project_root
        )

      assert entry.relative_path == "lib/meta.ex"
      assert entry.line == 4
      assert entry.column == 2
      assert entry.code == :warn_return_no_exit
    end

    test "handles warnings without locations" do
      project_root = Path.expand("tmp/ignore_project_nil")
      warning_text = "warning"

      Application.put_env(:assay, :dialyzer_warning_text, warning_text)

      [entry] =
        Ignore.decorate(
          [{:warn_return_no_exit, nil, "details"}],
          project_root
        )

      assert entry.path == nil
      assert entry.relative_path == nil
      assert entry.line == nil
      assert entry.column == nil
    end

    test "handles absolute warning paths" do
      project_root = Path.expand("tmp/ignore_project_abs")
      abs_path = Path.join(project_root, "lib/abs.ex")
      warning_text = "#{abs_path}:1: warning"

      Application.put_env(:assay, :dialyzer_warning_text, warning_text)

      [entry] =
        Ignore.decorate(
          [{:warn_return_no_exit, {abs_path, {1, 1}}, "details"}],
          project_root
        )

      assert entry.path == abs_path
      assert entry.relative_path == "lib/abs.ex"
    end

    test "normalizes atom file names and unknown codes" do
      project_root = Path.expand("tmp/ignore_project_atom")
      warning_text = "#{project_root}/sample:10: warning"

      Application.put_env(:assay, :dialyzer_warning_text, warning_text)

      [entry] =
        Ignore.decorate(
          [{123, {:sample, 10}, "details"}],
          project_root
        )

      assert entry.relative_path == "sample"
      assert entry.path == Path.join(project_root, "sample")
      assert entry.line == 10
      assert entry.code == :unknown
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

    test "treats false ignore_file as disabled", %{entry: entry} do
      result = Ignore.filter([entry], false)
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

    test "matches string, regex, and code rules", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_map")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      rules = """
      [
        "lib/sample.ex",
        ~r/ignore/,
        %{code: :warn_return_no_exit, line: 3, message: "warning"}
      ]
      """

      File.write!(ignore_file, rules)

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file)

      assert kept == []
      assert ignored == [entry]
    end

    test "matches list patterns for file and code", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_list")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      rules = """
      [
        %{relative: ~c"lib/sample.ex", code: ~c"warn_return_no_exit"}
      ]
      """

      File.write!(ignore_file, rules)

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file)

      assert kept == []
      assert ignored == [entry]
    end

    test "raises when ignore file returns non-list", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_bad")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))
      File.write!(ignore_file, ":not_a_list")

      assert_raise Mix.Error, ~r/must return a list/, fn ->
        Ignore.filter([entry], ignore_file)
      end
    end

    test "matches tag-based rules", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_tag")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))
      File.write!(ignore_file, ~S([%{tag: :warn_return_no_exit}]))

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file)

      assert kept == []
      assert ignored == [entry]
    end

    test "matches file-based rules and charlist patterns", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_file")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      rules = """
      [
        %{file: "sample.ex"},
        ~c"lib/sample.ex",
        %{code: "warn_return_no_exit"}
      ]
      """

      File.write!(ignore_file, rules)

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file)

      assert kept == []
      assert ignored == [entry]
    end

    test "raises when ignore file evaluation fails", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_error")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))
      File.write!(ignore_file, "raise \"boom\"")

      assert_raise Mix.Error, ~r/Failed to load/, fn ->
        Ignore.filter([entry], ignore_file)
      end
    end

    test "keeps entries when rules do not match", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_keep")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      File.write!(ignore_file, ~S(["other.ex"]))

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file)

      assert kept == [entry]
      assert ignored == []
    end

    test "tracks matched rules when explain? is true", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_explain")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      File.write!(ignore_file, ~S(["lib/sample.ex", ~r/warning/]))

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file, explain?: true)

      assert kept == []
      assert length(ignored) == 1

      [ignored_entry] = ignored
      assert Map.has_key?(ignored_entry, :matched_rules)
      matched_rules = ignored_entry.matched_rules
      assert length(matched_rules) == 2
      # Should have both rules (index 0 and 1)
      assert {0, _} = Enum.find(matched_rules, fn {idx, _} -> idx == 0 end)
      assert {1, _} = Enum.find(matched_rules, fn {idx, _} -> idx == 1 end)
    end

    test "does not track matched rules when explain? is false", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_no_explain")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      File.write!(ignore_file, ~S(["lib/sample.ex"]))

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file, explain?: false)

      assert kept == []
      assert length(ignored) == 1

      [ignored_entry] = ignored
      refute Map.has_key?(ignored_entry, :matched_rules)
    end

    test "ignores unknown rule keys and invalid patterns", %{entry: entry} do
      project_root = Path.expand("tmp/ignore_project_unknown")
      ignore_file = Path.join(project_root, "dialyzer_ignore.exs")
      File.mkdir_p!(Path.dirname(ignore_file))

      rules = """
      [
        %{unknown: "value"},
        %{message: 123}
      ]
      """

      File.write!(ignore_file, rules)

      {kept, ignored, _path} = Ignore.filter([entry], ignore_file)

      assert kept == [entry]
      assert ignored == []
    end
  end
end

defmodule Assay.IgnoreTestDialyzer do
  @moduledoc false

  def format_warning(_warning, _opts) do
    Application.get_env(:assay, :dialyzer_warning_text, "dialyzer warning")
  end
end
