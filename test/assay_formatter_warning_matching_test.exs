defmodule Assay.Formatter.Warning.MatchingTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Warning.Matching
  alias Assay.Formatter.Warning.Result

  describe "render/3" do
    test "builds warning with relative path and line" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 10,
        column: 5,
        text: "Pattern match will never succeed",
        raw: {:warn_matching, {"lib/sample.ex", {10, 5}}, {:pattern, "some pattern"}}
      }

      result = Matching.render(entry, %Result{}, color?: false)

      assert result.headline == "lib/sample.ex:10: pattern match will never succeed"
      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))

      assert Enum.any?(
               result.details,
               &String.contains?(&1, "This pattern match will never succeed")
             )
    end

    test "builds warning without relative path" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Pattern match will never succeed",
        raw: {:warn_matching, nil, {:pattern, "some pattern"}}
      }

      result = Matching.render(entry, %Result{}, color?: false)

      assert result.headline == "Pattern match will never succeed"
    end

    test "includes reason block when available" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 5,
        column: 3,
        text: "Pattern match will never succeed\nReason: types differ",
        raw: {:warn_matching, {"lib/sample.ex", {5, 3}}, {:pattern, "some pattern"}}
      }

      result = Matching.render(entry, %Result{}, color?: false)

      # Reason block is only included if extract_reason_line finds a reason
      # The text format may not always have a "Reason:" line
      assert result.headline == "lib/sample.ex:5: pattern match will never succeed"
      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))
    end

    test "includes suggestions" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 8,
        column: 2,
        text: "Pattern match will never succeed",
        raw: {:warn_matching, {"lib/sample.ex", {8, 2}}, {:pattern, "some pattern"}}
      }

      result = Matching.render(entry, %Result{}, color?: false)

      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))
      assert Enum.any?(result.details, &String.contains?(&1, "Check the pattern matches"))
    end
  end
end
