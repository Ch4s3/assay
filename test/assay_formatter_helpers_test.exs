defmodule Assay.Formatter.HelpersTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Helpers

  describe "format_term_lines/1" do
    test "handles nil and printable binaries" do
      assert Helpers.format_term_lines(nil) == []

      assert Helpers.format_term_lines("%{title => <<116,105,116,108,101>>}") ==
               ["%{title => \"title\"}"]
    end

    test "handles chardata and non-printable bitstrings" do
      [line] = Helpers.format_term_lines(~c"hello")
      assert String.contains?(line, "hello")
      assert Helpers.format_term_lines("<<1,2,3>>") == ["<<1, 2, 3>>"]
    end
  end

  describe "diff_lines/3" do
    test "renders spec diffs inline" do
      lines =
        Helpers.diff_lines(
          ["(integer()) :: integer()"],
          ["(integer()) :: atom()"],
          color?: false
        )
        |> List.flatten()

      assert "-  (integer()) :: integer()" in lines
      assert "+  (integer()) :: atom()" in lines
    end

    test "renders map entries and highlights nested diffs" do
      lines =
        Helpers.diff_lines(
          ["%{a => (integer()), b => (atom())}"],
          ["%{a => (binary()), b => (atom())}"],
          color?: false
        )
        |> List.flatten()

      assert Enum.any?(lines, &String.contains?(&1, "-  a => (integer())"))
      assert Enum.any?(lines, &String.contains?(&1, "+  a => (binary())"))
    end

    test "renders insertions and deletions for missing map keys" do
      lines =
        Helpers.diff_lines(
          ["%{a => 1, b => 2}"],
          ["%{a => 1, c => 3}"],
          color?: false
        )
        |> List.flatten()

      assert Enum.any?(lines, &String.contains?(&1, "-  b => 2"))
      assert Enum.any?(lines, &String.contains?(&1, "+  c => 3"))
    end

    test "formats nested map entries when falling back to Myers diff" do
      lines =
        Helpers.diff_lines(
          ["%{bad, nested => %{alpha => 1, beta => 2}}"],
          ["%{bad, nested => %{alpha => 1, beta => 3}}"],
          color?: false
        )
        |> List.flatten()

      assert Enum.any?(lines, &String.contains?(&1, "nested => %{"))
      assert Enum.any?(lines, &String.contains?(&1, "beta => 3"))
      assert Enum.any?(lines, &String.contains?(&1, "bad"))
    end

    test "includes ANSI wrappers when color is enabled" do
      lines =
        Helpers.diff_lines(["alpha"], ["beta"], color?: true)
        |> List.flatten()

      assert Enum.any?(lines, &String.contains?(&1, "\e["))
    end

    test "falls back to Myers diff when no structured format matches" do
      lines =
        Helpers.diff_lines(["foo"], ["bar"], color?: false)
        |> List.flatten()

      assert lines == ["-  foo", "+  bar"]
    end
  end

  describe "colorize/3" do
    test "only wraps text when enabled" do
      assert Helpers.colorize("plain", :blue, false) == "plain"
      assert Helpers.colorize("plain", nil, true) == "plain"

      colorized = Helpers.colorize("plain", :blue, true)
      assert String.starts_with?(colorized, "\e[")
      assert String.ends_with?(colorized, "\e[0m")
      assert colorized != "plain"
    end
  end
end
