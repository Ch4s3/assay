defmodule Assay.Formatter.HelpersTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Helpers

  describe "format_term_lines/1" do
    test "stringifies printable binaries and placeholder bit specs" do
      lines =
        Helpers.format_term_lines(
          "%{:metadata => %{:count => <<_ :: 32>>, :extras => %{:source => <<116,105,116,108,101>>}}}"
        )

      joined = Enum.join(lines, "\n")

      assert joined =~ "\"<<_ :: 32>>\""
      assert joined =~ "\"title\""
    end
  end

  describe "diff_lines/3" do
    test "highlights nested map entry differences recursively" do
      expected = [
        "(%{:items => maybe_improper_list(), :metadata => %{:count => integer(), :extras => %{:source => atom(), _ => _}}, :status => :ok, _ => _})"
      ]

      actual = [
        "(%{:items => [%{:unexpected => :entry}], :metadata => %{:count => <<_ :: 32>>, :extras => %{:source => <<_ :: 24>>}}, :status => :error, <<_ :: 48>> => %{<<_ :: 56>> => 123}})"
      ]

      lines =
        expected
        |> Helpers.diff_lines(actual, color?: false)
        |> List.flatten()

      assert "-  :items => maybe_improper_list()" in lines
      assert "+  :items => [%{:unexpected => :entry}]" in lines

      assert "-  :metadata => %{:count => integer(), :extras => %{:source => atom(), _ => _}}" in lines

      assert ~S(+  :metadata => %{:count => "<<_ :: 32>>", :extras => %{:source => "<<_ :: 24>>"}}) in lines

      assert ~S(+  "<<_ :: 48>>" => %{"<<_ :: 56>>" => 123}) in lines
    end

    test "keeps specification delimiters balanced even after highlighting" do
      expected = ["([integer()]) :: integer() | nil"]
      actual = ["(maybe_improper_list()) :: any()"]

      [[del_line], [ins_line]] = Helpers.diff_lines(expected, actual, color?: true)

      clean_del = strip_ansi(del_line)
      clean_ins = strip_ansi(ins_line)

      assert clean_del =~ "([integer()]) :: integer() | nil"
      assert clean_ins =~ "(maybe_improper_list()) :: any()"

      assert balanced?(clean_del)
      assert balanced?(clean_ins)
    end
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[\d;]*m/, text, "")
  end

  defp balanced?(line) do
    line
    |> String.graphemes()
    |> Enum.reduce_while([], fn
      "(", stack -> {:cont, ["(" | stack]}
      "[", stack -> {:cont, ["[" | stack]}
      "{", stack -> {:cont, ["{" | stack]}
      ")", ["(" | rest] -> {:cont, rest}
      "]", ["[" | rest] -> {:cont, rest}
      "}", ["{" | rest] -> {:cont, rest}
      ")", _ -> {:halt, :error}
      "]", _ -> {:halt, :error}
      "}", _ -> {:halt, :error}
      _, stack -> {:cont, stack}
    end)
    |> case do
      :error -> false
      [] -> true
      _ -> false
    end
  end
end
