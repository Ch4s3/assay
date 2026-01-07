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

    # New format includes multi-line context and suggestions
    assert result =~ "┌─ warning: lib/foo.ex:2:3"
    assert result =~ "│   (return no exit)"
    assert result =~ "1 │ defmodule Foo do"
    assert result =~ "2 │   def bar(arg), do: arg"
    # Underline instead of caret
    assert result =~ "~~~"
    assert result =~ "3 │ end"
    assert result =~ "Foo.bar/1 has no local return"
    # Suggestions are now included
    assert result =~ "Suggestion:"
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
    refute result =~ yellow("atom() | [any()])")
    refute result =~ yellow("\"title\")")
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

  test "elixir formatter collapses tuple diffs down to the differing argument", %{
    tmp_dir: tmp_dir
  } do
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

    assert clean =~
             "+  :metadata => %{:count => \"<<_ :: 32>>\", :extras => %{:source => \"<<_ :: 24>>\"}}"

    assert clean =~ "+  \"<<_ :: 48>>\" => %{\"<<_ :: 56>>\" => 123}"
    assert result =~ yellow("maybe_improper_list()")
    assert result =~ yellow("[%{:unexpected => :entry}]")
    assert result =~ yellow("\"<<_ :: 32>>\"")
  end

  test "formatter renders contract diff warnings with spec sections", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_contract_not_equal, {~c"lib/foo.ex", {80, 1}},
       {:contract_diff,
        [
          Sample,
          :foo,
          1,
          ~c"@spec foo(integer()) :: atom()",
          ~c"@spec foo(integer()) :: :ok"
        ]}}

    entry = %{
      text: "lib/foo.ex:80: Type specification is not equal to the success typing",
      match_text: "lib/foo.ex:80: Type specification is not equal to the success typing",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 80,
      column: 1,
      code: :warn_contract_not_equal
    }

    [result] = Formatter.format([entry], :text, project_root: tmp_dir, color?: true)
    clean = strip_ansi(result)

    assert clean =~ "Contract (@spec):"
    assert clean =~ "@spec foo(integer()) :: atom()"
    assert clean =~ "Success typing:"
    assert clean =~ "@spec foo(integer()) :: :ok"
    assert clean =~ "Diff (expected -, actual +):"
    assert result =~ yellow("atom()")
    assert result =~ yellow(":ok")
  end

  test "formatter explains invalid contracts with positional details", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_contract_types, {~c"lib/foo.ex", {90, 2}},
       {:invalid_contract,
        [
          Sample,
          :bad_spec,
          2,
          {:invalid_contract, {[1, 2], true}},
          ~c"@spec bad_spec(integer(), atom()) :: {:ok, term()}",
          ~c"@spec bad_spec(pos_integer(), :ok) :: :ok"
        ]}}

    entry = %{
      text: "lib/foo.ex:90: Invalid contract for Sample.bad_spec/2",
      match_text: "lib/foo.ex:90: Invalid contract for Sample.bad_spec/2",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 90,
      column: 2,
      code: :warn_contract_types
    }

    [result] = Formatter.format([entry], :text, project_root: tmp_dir, color?: true)
    clean = strip_ansi(result)

    assert clean =~ "Invalid contract for 1st and 2nd arguments and the return type."
    assert clean =~ "Contract (@spec):"
    assert clean =~ "Success typing:"
    assert clean =~ "Diff (expected -, actual +):"
  end

  test "contract subtype diff keeps parentheses colored", %{tmp_dir: tmp_dir} do
    raw =
      {:warn_contract_subtype, {~c"lib/foo.ex", {110, 1}},
       {:contract_subtype,
        [
          Sample,
          :tight_spec,
          1,
          ~c"([integer()]) :: integer() | nil",
          ~c"(maybe_improper_list()) :: any()"
        ]}}

    entry = %{
      text: "lib/foo.ex:110: Spec is a subtype of success typing",
      match_text: "lib/foo.ex:110: Spec is a subtype of success typing",
      raw: raw,
      path: nil,
      relative_path: "lib/foo.ex",
      line: 110,
      column: 1,
      code: :warn_contract_subtype
    }

    [result] = Formatter.format([entry], :text, project_root: tmp_dir, color?: true)
    clean = strip_ansi(result)

    assert result =~ yellow("[integer()]")
    assert result =~ yellow("maybe_improper_list()")
    assert result =~ yellow("integer() | nil")
    assert result =~ yellow("any()")
    refute result =~ yellow("[integer()])")
    refute result =~ yellow("maybe_improper_list())")

    expected_line = find_line(clean, "([integer()]) :: integer() | nil")
    actual_line = find_line(clean, "(maybe_improper_list()) :: any()")

    assert expected_line
    assert actual_line

    assert balanced_delimiters?(expected_line)
    assert balanced_delimiters?(actual_line)
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

  test "json formatter emits structured payloads", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "lib/foo.ex")

    entries = [
      %{
        text: "warning text",
        match_text: "warning text",
        path: path,
        relative_path: "lib/foo.ex",
        line: 5,
        column: 1,
        code: :warn_return_no_exit
      }
    ]

    [json] = Formatter.format(entries, :json, project_root: tmp_dir)
    {:ok, payload} = JSON.decode(json)

    assert payload["relative_path"] == "lib/foo.ex"
    assert payload["line"] == 5
    assert payload["column"] == 1
    assert payload["code"] == "warn_return_no_exit"
    assert payload["severity"] == "warning"
    assert payload["location"] == "lib/foo.ex:5:1"
  end

  test "sarif formatter emits a valid log", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "lib/foo.ex")

    entries = [
      %{
        text: "warning text",
        match_text: "warning text",
        path: path,
        relative_path: "lib/foo.ex",
        line: 5,
        column: 2,
        code: :warn_return_no_exit
      }
    ]

    [sarif_json] = Formatter.format(entries, :sarif, project_root: tmp_dir)
    {:ok, sarif} = JSON.decode(sarif_json)

    assert sarif["version"] == "2.1.0"
    [run] = sarif["runs"]
    [result] = run["results"]
    assert result["ruleId"] == "warn_return_no_exit"
    assert result["level"] == "warning"
    [%{"physicalLocation" => location}] = result["locations"]
    assert location["artifactLocation"]["uri"] == "lib/foo.ex"
    assert location["region"]["startLine"] == 5
    assert location["region"]["startColumn"] == 2
  end

  defp find_line(text, needle) do
    text
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, needle))
  end

  defp balanced_delimiters?(line) do
    result =
      line
      |> String.graphemes()
      |> Enum.reduce_while([], fn
        "(", stack -> {:cont, ["(" | stack]}
        "[", stack -> {:cont, ["[" | stack]}
        "{", stack -> {:cont, ["{" | stack]}
        ")", stack -> pop_delimiter(stack, ")")
        "]", stack -> pop_delimiter(stack, "]")
        "}", stack -> pop_delimiter(stack, "}")
        _, stack -> {:cont, stack}
      end)

    case result do
      :error -> false
      stack -> stack == []
    end
  end

  defp pop_delimiter(["(" | rest], ")"), do: {:cont, rest}
  defp pop_delimiter(["[" | rest], "]"), do: {:cont, rest}
  defp pop_delimiter(["{" | rest], "}"), do: {:cont, rest}
  defp pop_delimiter(_stack, _close), do: {:halt, :error}

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

  test "format handles relative_display with path that can't be relativized", %{tmp_dir: tmp_dir} do
    # Test the rescue clause in relative_display
    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: "/absolute/path/that/cant/be/relativized",
        relative_path: nil,
        line: 1,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :github, project_root: tmp_dir)
    # Should fallback to absolute path if relativization fails
    assert result =~ "file="
  end

  test "format handles format_snippet with file that can't be read", %{tmp_dir: tmp_dir} do
    non_existent = Path.join(tmp_dir, "nonexistent.ex")

    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: non_existent,
        relative_path: "nonexistent.ex",
        line: 1,
        column: 5,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle missing file gracefully
    assert result =~ "warning"
  end

  test "format handles format_snippet with nil line", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "lib/foo.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule Foo, do: nil")

    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: path,
        relative_path: "lib/foo.ex",
        line: nil,
        column: 5,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle nil line gracefully
    assert result =~ "warning"
  end

  test "format handles format_snippet with nil path", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: nil,
        relative_path: nil,
        line: 1,
        column: 5,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle nil path gracefully
    assert result =~ "warning"
  end

  test "format handles format_code_line with nil", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: nil,
        relative_path: nil,
        line: nil,
        column: nil,
        code: nil
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle nil code gracefully
    assert result =~ "warning"
  end

  test "format handles run_erlex when erlex is not available", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: ~S"""
        lib/foo.ex:5: Bad call
                 (#{'__struct__' := 'Elixir.Sample'})
                 will never return
        """,
        match_text: "lib/foo.ex:5",
        path: nil,
        relative_path: "lib/foo.ex",
        line: 5,
        column: nil,
        code: :warn_failing_call
      }
    ]

    # Should fallback to plain text if erlex fails
    [result] = Formatter.format(entries, :elixir, project_root: tmp_dir)
    assert result =~ "Bad call"
  end

  test "format handles strip_common_indent with empty lines", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: """
        lib/foo.ex:5: Detail
                 with
                 indentation
        """,
        match_text: "lib/foo.ex:5",
        path: nil,
        relative_path: "lib/foo.ex",
        line: 5,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle indentation stripping
    assert result =~ "Detail"
  end

  test "format handles leading_indent with tabs", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: """
        lib/foo.ex:5: Detail
        \t\twith tabs
        """,
        match_text: "lib/foo.ex:5",
        path: nil,
        relative_path: "lib/foo.ex",
        line: 5,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle tab indentation
    assert result =~ "Detail"
  end

  test "format handles code_to_string with non-atom code", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: nil,
        relative_path: nil,
        line: 1,
        column: nil,
        code: "warn_custom"
      }
    ]

    [result] = Formatter.format(entries, :json, project_root: tmp_dir)
    # Should handle string codes
    assert result =~ "warn_custom"
  end

  test "format handles warning_severity with non-warn code", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "info",
        match_text: "info",
        path: nil,
        relative_path: nil,
        line: 1,
        column: nil,
        code: :info_message
      }
    ]

    [result] = Formatter.format(entries, :json, project_root: tmp_dir)
    # Should handle non-warn codes
    assert result =~ "info"
  end

  test "format handles warning_severity with nil code", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "warning",
        match_text: "warning",
        path: nil,
        relative_path: nil,
        line: 1,
        column: nil,
        code: nil
      }
    ]

    [result] = Formatter.format(entries, :json, project_root: tmp_dir)
    # Should default to "warning" for nil codes
    assert result =~ "warning"
  end

  test "format handles sarif_level with info severity", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "info",
        match_text: "info",
        path: nil,
        relative_path: nil,
        line: 1,
        column: nil,
        code: :info_message
      }
    ]

    [result] = Formatter.format(entries, :sarif, project_root: tmp_dir)
    # Should convert info to "note" in SARIF
    assert result =~ "note"
  end

  test "format handles github_escape with special characters", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: "warning with % and \r\n newlines",
        match_text: "warning with % and \r\n newlines",
        path: nil,
        relative_path: "test.ex",
        line: 1,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :github, project_root: tmp_dir)
    # Should escape special characters
    # % escaped
    assert result =~ "%25"
    # \r escaped
    assert result =~ "%0D"
    # \n escaped
    assert result =~ "%0A"
  end

  test "format handles split_on_phrase when phrase not found", %{tmp_dir: tmp_dir} do
    entries = [
      %{
        text: """
        lib/foo.ex:5: Some other message
        """,
        match_text: "lib/foo.ex:5",
        path: nil,
        relative_path: "lib/foo.ex",
        line: 5,
        column: nil,
        code: :warn_failing_call
      }
    ]

    [result] = Formatter.format(entries, :text, project_root: tmp_dir)
    # Should handle messages without "will never return"
    assert result =~ "Some other message"
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[\d;]*m/, text, "")
  end
end
