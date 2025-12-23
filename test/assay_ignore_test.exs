defmodule Assay.IgnoreTest do
  use ExUnit.Case, async: true

  alias Assay.Ignore

  @moduletag :tmp_dir

  setup do
    Application.put_env(:assay, :dialyzer_module, __MODULE__.DialyzerStub)

    on_exit(fn ->
      Application.delete_env(:assay, :dialyzer_module)
    end)

    :ok
  end

  describe "decorate/2" do
    test "normalizes absolute and relative metadata", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "lib/foo.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Foo do end")

      [entry] = Ignore.decorate([warning_fixture(file)], tmp_dir)

      assert entry.path == file
      assert entry.relative_path == "lib/foo.ex"
      assert entry.line == 4
      assert entry.column == 1
      assert entry.code == :warn_failing_call
      assert entry.match_text == "dialyzer warning"
      assert entry.text == "dialyzer warning"
    end

    test "handles nil, binary, atom, and unsupported file identifiers", %{tmp_dir: tmp_dir} do
      nil_entry =
        Ignore.decorate([warning_fixture(nil, location_file: nil, message: "nil path")], tmp_dir)
        |> hd()

      binary_file = "binary_file.ex"

      binary_entry =
        Ignore.decorate(
          [warning_fixture(tmp_dir, location_file: binary_file, message: "binary path")],
          tmp_dir
        )
        |> hd()

      atom_entry =
        Ignore.decorate(
          [warning_fixture(tmp_dir, location_file: :custom_atom, message: "atom path")],
          tmp_dir
        )
        |> hd()

      fallback_entry =
        Ignore.decorate(
          [
            warning_fixture(tmp_dir, location_file: %{unexpected: true}, message: "fallback path")
          ],
          tmp_dir
        )
        |> hd()

      assert nil_entry.path == nil
      assert binary_entry.path == Path.expand(binary_file, tmp_dir)
      assert atom_entry.path == Path.expand("custom_atom", tmp_dir)
      assert fallback_entry.path == nil
    end
  end

  describe "filter/2" do
    test "returns entries untouched when the ignore file is missing", %{tmp_dir: tmp_dir} do
      entries = Ignore.decorate([warning_fixture(Path.join(tmp_dir, "lib/foo.ex"))], tmp_dir)

      {kept, ignored, path} = Ignore.filter(entries, Path.join(tmp_dir, "missing.exs"))

      assert kept == entries
      assert ignored == []
      assert path == nil
    end

    test "applies string, regex, and map rules", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "lib/foo.ex")
      entries = Ignore.decorate([warning_fixture(file)], tmp_dir)

      ignore_path = Path.join(tmp_dir, "dialyzer_ignore.exs")

      File.write!(ignore_path, """
      [
        "dialyzer warning",
        %{
          file: "lib/foo.ex",
          message: "dialyzer warning",
          line: 4,
          code: :warn_failing_call
        },
        ~r/foo\\.ex/
      ]
      """)

      {kept, ignored, path} = Ignore.filter(entries, ignore_path)

      assert kept == []
      assert ignored == entries
      assert path == ignore_path
    end

    test "handles charlist, regex, and code-specific rules", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "lib/multi.ex")

      entries =
        [
          warning_fixture(file, message: "alpha", code: {:warn_custom, [:meta]}),
          warning_fixture(file, message: "beta", code: :warn_custom),
          warning_fixture(file, message: "gamma", code: 123)
        ]
        |> Ignore.decorate(tmp_dir)

      ignore_path = Path.join(tmp_dir, "charlist_rules.exs")

      File.write!(ignore_path, """
      [
        %{message: ~c"nope"},
        %{message: ~r/beta/, code: :warn_custom},
        %{message: %{}},
        %{code: "warn_custom"},
        %{code: ~c"warn_custom"},
        %{code: :warn_custom},
        %{code: 123},
        %{code: :unknown}
      ]
      """)

      {kept, ignored, path} = Ignore.filter(entries, ignore_path)

      assert kept == []
      assert length(ignored) == 3
      assert path == ignore_path
    end

    test "raises when ignore file does not return a list", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "bad_ignore.exs")
      File.write!(file, "%{oops: true}")

      entries = Ignore.decorate([warning_fixture(Path.join(tmp_dir, "lib/foo.ex"))], tmp_dir)

      assert_raise Mix.Error, fn ->
        Ignore.filter(entries, file)
      end
    end
  end

  defp warning_fixture(file, opts \\ []) do
    code = Keyword.get(opts, :code, :warn_failing_call)
    message = Keyword.get(opts, :message, "dialyzer warning")
    location_file = Keyword.get(opts, :location_file, default_location_file(file))
    line = Keyword.get(opts, :line, 4)
    column = Keyword.get(opts, :column, 1)
    location = {location_file, {line, column}}

    {code, location, message}
  end

  defp default_location_file(nil), do: nil
  defp default_location_file(file) when is_binary(file), do: String.to_charlist(file)
  defp default_location_file(file), do: file

  defmodule DialyzerStub do
    def format_warning({_code, _location, message}, _opts) do
      message
      |> to_string()
      |> String.to_charlist()
    end
  end
end
