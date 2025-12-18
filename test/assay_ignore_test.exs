defmodule Assay.IgnoreTest do
  use ExUnit.Case, async: true

  alias Assay.Ignore

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("assay_ignore_test")

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp}
  end

  test "filter leaves warnings untouched when ignore file is disabled" do
    entries = [entry_fixture(match_text: "keep me")]

    assert {^entries, [], nil} = Ignore.filter(entries, nil)
  end

  test "filter ignores warnings via regex rules", %{tmp: tmp} do
    ignore_file = write_ignore(tmp, "[~r/foo/]")
    entries = [entry_fixture(match_text: "foo bar")]

    assert {[], [ignored], ^ignore_file} = Ignore.filter(entries, ignore_file)
    assert ignored.match_text == "foo bar"
  end

  test "filter matches map rules by file and line", %{tmp: tmp} do
    ignore_file = write_ignore(tmp, "[%{file: \"file.ex\", line: 99}]")
    path = Path.join(tmp, "file.ex")
    entries = [entry_fixture(path: path, relative_path: "file.ex", line: 99)]

    assert {[], [_ignored], ^ignore_file} = Ignore.filter(entries, ignore_file)
  end

  defp entry_fixture(overrides) do
    defaults = %{
      raw: :warning,
      text: "warning text\n",
      match_text: "warning text\n",
      path: "/tmp/file.ex",
      relative_path: "file.ex",
      line: 1,
      code: :warn_custom
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp write_ignore(tmp, contents) do
    path = Path.join(tmp, "dialyzer_ignore.exs")
    File.write!(path, contents)
    path
  end
end
