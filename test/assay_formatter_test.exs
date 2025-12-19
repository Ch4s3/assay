defmodule Assay.FormatterTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Assay.Formatter

  test "text formatter renders friendly diagnostics with snippets", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "lib/foo.ex")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    defmodule Foo do
      def bar(arg), do: arg
    end
    """)

    entries = [
      %{
        text: "lib/foo.ex:2: Function Foo.bar/1 has no local return",
        match_text: "#{path}:2: Function Foo.bar/1 has no local return",
        path: path,
        relative_path: "lib/foo.ex",
        line: 2,
        column: 3,
        code: :warn_return_no_exit
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)

    expected = """
    ┌─ warning: lib/foo.ex:2:3
    │   (return no exit)
    │
    2 │   def bar(arg), do: arg
      │   ^
    │
    └─ Function Foo.bar/1 has no local return
    """

    assert result == String.trim_trailing(expected)
  end

  test "text formatter falls back when file context is missing", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "warning text",
        match_text: "warning text",
        path: nil,
        relative_path: nil,
        line: nil,
        column: nil,
        code: nil
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)

    expected = """
    ┌─ warning: nofile
    │
    └─ warning text
    """

    assert result == String.trim_trailing(expected)
  end

  test "text formatter renders detail blocks as code-friendly sections", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: """
        lib/bar.ex:10: The call 'Elixir.Sample':foo/1
                 (actual args) will never return since it differs:
                 (expected args)
        """,
        match_text: "lib/bar.ex:10: detail block",
        path: nil,
        relative_path: "lib/bar.ex",
        line: 10,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)

    expected = """
    ┌─ warning: lib/bar.ex:10
    │   (failing call)
    │
    │ (actual args)
    │ -> will never return since it differs:
    │ (expected args)
    └─ The call 'Elixir.Sample':foo/1
    """

    assert result == String.trim_trailing(expected)
  end

  test "text formatter can pretty print Erlang detail blocks with erlex", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: ~S"""
        lib/foo.ex:5: Bad call
                 (#{'__struct__' := 'Elixir.Sample', 'title' := <<116,105,116,108,101>>})
                 will never return since it differs:
                 (#{'__struct__' := 'Elixir.Sample', 'title' := binary()})
        """,
        match_text: "lib/foo.ex:5",
        path: nil,
        relative_path: "lib/foo.ex",
        line: 5,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [pretty] = Formatter.format(entries, :elixir, project_root: tmp_dir)
    assert pretty =~ "%Sample{:title => <<116, 105, 116, 108, 101>>}"
    assert pretty =~ "-> will never return"

    [plain] = Formatter.format(entries, :text, project_root: tmp_dir)
    assert plain =~ "\#{'__struct__'"
  end

  test "text formatter highlights diff for failing call warnings", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {12, 4}},
       {:call, [Sample, :foo, ~c"(binary())", [], :only_sig, ~c"(atom())", ~c"type"]}}

    entries = [
      %{
        text: "lib/foo.ex:12: The call Sample.foo/1 will never return since types differ",
        match_text: "lib/foo.ex:12: The call Sample.foo/1 will never return since types differ",
        raw: raw,
        path: nil,
        relative_path: "lib/foo.ex",
        line: 12,
        column: 4,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)

    assert result =~ "Expected (success typing):"
    assert result =~ "Actual (call arguments):"
    assert result =~ "Diff (expected -, actual +):"
    assert result =~ "-  (atom())"
    assert result =~ "+  (binary())"
  end

  test "elixir formatter highlights only differing segments when colors are enabled",
       %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {20, 1}},
       {:call,
        [
          Sample,
          :foo,
          ~c"(%Sample{}, \"title\")",
          [],
          :only_sig,
          ~c"(%Sample{}, atom() | [any()])",
          ~c"type"
        ]}}

    entries = [
      %{
        text: "lib/foo.ex:20: The call Sample.foo/1 will never return since types differ",
        match_text: "lib/foo.ex:20: The call Sample.foo/1 will never return since types differ",
        raw: raw,
        path: nil,
        relative_path: "lib/foo.ex",
        line: 20,
        column: 1,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir, color?: true)

    assert result =~ yellow("atom() | [any()]")
    assert result =~ yellow("\"title\"")
  end

  test "elixir formatter compacts struct diffs and renders printable binaries",
       %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {30, 2}},
       {:call,
        [
          Sample,
          :foo,
          ~c"(%Sample{:required => <<116,105,116,108,101>>})",
          [],
          :only_sig,
          ~c"(%Sample{:required => atom() | [any()]})",
          ~c"type"
        ]}}

    entries = [
      %{
        text: "lib/foo.ex:30: The call Sample.foo/1 will never return since types differ",
        match_text: "lib/foo.ex:30: The call Sample.foo/1 will never return since types differ",
        raw: raw,
        path: nil,
        relative_path: "lib/foo.ex",
        line: 30,
        column: 2,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :elixir, project_root: tmp_dir)

    assert result =~ "-  (%Sample{..., :required => atom() | [any()]})"
    assert result =~ "+  (%Sample{..., :required => \"title\"})"
  end

  test "elixir formatter collapses tuple diffs down to the differing argument", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {40, 1}},
       {:call,
        [
          Sample,
          :foo,
          ~c"(%Sample{:value => atom()}, atom())",
          [],
          :only_sig,
          ~c"(%Sample{:value => atom()}, \"title\")",
          ~c"type"
        ]}}

    entry = %{
      text: "lib/foo.ex:40: The call Sample.foo/2 will never return since types differ",
      match_text: "lib/foo.ex:40: The call Sample.foo/2 will never return since types differ",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 40,
      column: 1,
      code: :warn_failing_call
    }

    [result] = Formatter.format([entry], :elixir, project_root: tmp_dir)

    assert result =~ "-  (%Sample{...}, \"title\")"
    assert result =~ "+  (%Sample{...}, atom())"
  end

  test "elixir formatter pinpoints nested struct field differences", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {50, 1}},
       {:call,
        [
          Outer,
          :run,
          ~c"(%Outer{:inner => %Inner{:foo => atom(), :bar => integer()}})",
          [],
          :only_sig,
          ~c"(%Outer{:inner => %Inner{:foo => \"title\", :bar => integer()}})",
          ~c"type"
        ]}}

    entry = %{
      text: "lib/foo.ex:50: Outer.run will never return since nested types differ",
      match_text: "lib/foo.ex:50: Outer.run will never return since nested types differ",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 50,
      column: 1,
      code: :warn_failing_call
    }

    [result] = Formatter.format([entry], :elixir, project_root: tmp_dir)

    assert result =~ "-  (%Outer{..., :foo => \"title\"})"
    assert result =~ "+  (%Outer{..., :foo => atom()})"
  end

  test "elixir formatter leaves non printable binaries untouched", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {60, 1}},
       {:call,
        [
          Sample,
          :data,
          ~c"(<<0,255>>)",
          [],
          :only_sig,
          ~c"(<<116,105,116,108,101>>)",
          ~c"type"
        ]}}

    entry = %{
      text: "lib/foo.ex:60: Sample.data will never return due to binary mismatch",
      match_text: "lib/foo.ex:60: Sample.data will never return due to binary mismatch",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 60,
      column: 1,
      code: :warn_failing_call
    }

    [result] = Formatter.format([entry], :elixir, project_root: tmp_dir)

    assert result =~ "-  (\"title\")"
    assert result =~ "+  (<<0, 255>>)"
  end

  test "elixir formatter compacts map diffs and stringifies placeholder bit specs",
       %{tmp_dir: tmp_dir} do
    raw =
      {:warn_failing_call, {~c"lib/foo.ex", {70, 1}},
       {:call,
        [
          Sample,
          :process,
          ~c"(%{:items => [%{:unexpected => :entry}], :metadata => %{:count => <<_ :: 32>>, :extras => %{:source => <<_ :: 24>>}}, :status => :error, <<_ :: 48>> => %{<<_ :: 56>> => 123}})",
          [],
          :only_sig,
          ~c"(%{:items => maybe_improper_list(), :labels => %{:primary => binary(), _ => _}, :metadata => %{:count => integer(), :extras => %{:source => atom(), _ => _}, _ => _}, :status => :ok, _ => _})",
          ~c"type"
        ]}}

    entry = %{
      text: "lib/foo.ex:70: Sample.process mismatches complex map types",
      match_text: "lib/foo.ex:70: Sample.process mismatches complex map types",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 70,
      column: 1,
      code: :warn_failing_call
    }

    [result] = Formatter.format([entry], :elixir, project_root: tmp_dir, color?: true)

    clean = strip_ansi(result)

    assert clean =~ "-  :items => maybe_improper_list()"
    assert clean =~ "+  :items => [%{:unexpected => :entry}]"
    assert clean =~ "-  :status => :ok"
    assert clean =~ "+  :status => :error"
    assert clean =~ "\"<<_ :: 24>>\""
    assert clean =~ "\"<<_ :: 56>>\""
    assert result =~ yellow("maybe_improper_list()")
    assert result =~ yellow("[%{:unexpected => :entry}]")
    assert result =~ yellow("\"<<_ :: 32>>\"")
    assert result =~ yellow("\"<<_ :: 24>>\"")
  end

  test "github formatter emits workflow command" do
    entries = [
      %{
        text: "warning text\n",
        match_text: "warning text",
        path: "/project/lib/foo.ex",
        relative_path: "lib/foo.ex",
        line: 10
      }
    ]

    result = Formatter.format(entries, :github, project_root: "/project")

    assert result == ["::warning file=lib/foo.ex,line=10::warning text"]
  end

  defp yellow(text) do
    prefix =
      :yellow
      |> IO.ANSI.format_fragment(true)
      |> IO.iodata_to_binary()

    reset =
      :reset
      |> IO.ANSI.format_fragment(true)
      |> IO.iodata_to_binary()

    prefix <> text <> reset
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[\d;]*m/, text, "")
  end
end
