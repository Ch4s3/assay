defmodule Assay.Formatter.HelpersTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Helpers

  describe "format_term_lines/1" do
    test "handles nil and printable binaries" do
      assert Helpers.format_term_lines(nil) == []

      assert Helpers.format_term_lines("%{title => <<116,105,116,108,101>>}") ==
               ["%{title => \"title\"}"]
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

      colorized = Helpers.colorize("plain", :blue, true)
      assert String.starts_with?(colorized, "\e[")
      assert String.ends_with?(colorized, "\e[0m")
      assert colorized != "plain"
    end
  end
end
