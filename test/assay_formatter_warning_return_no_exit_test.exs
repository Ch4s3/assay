defmodule Assay.Formatter.Warning.ReturnNoExitTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Warning.Result
  alias Assay.Formatter.Warning.ReturnNoExit

  describe "render/3" do
    test "builds warning with relative path, line, and call" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 5,
        column: 3,
        text: "Function MyApp.infinite/0 has no local return",
        raw:
          {:warn_return_no_exit, {"lib/sample.ex", {5, 3}},
           "Function MyApp.infinite/0 has no local return"}
      }

      result = ReturnNoExit.render(entry, %Result{}, color?: false)

      assert result.headline == "lib/sample.ex:5: MyApp.infinite/0 has no local return"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.infinite/0"))
      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))
    end

    test "builds warning without relative path but with call" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Function MyApp.loop/0 has no local return",
        raw: {:warn_return_no_exit, nil, "Function MyApp.loop/0 has no local return"}
      }

      result = ReturnNoExit.render(entry, %Result{}, color?: false)

      assert result.headline == "MyApp.loop/0 has no local return"
    end

    test "builds warning without call information" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Some warning text",
        raw: {:warn_return_no_exit, nil, "Some warning text"}
      }

      result = ReturnNoExit.render(entry, %Result{}, color?: false)

      assert result.headline == "Function has no local return"
      refute Enum.any?(result.details, &String.contains?(&1, "Function:"))
    end

    test "includes reason block when available" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 10,
        column: 3,
        text: "Function MyApp.recursive/1 has no local return\nReason: no local return",
        raw:
          {:warn_return_no_exit, {"lib/sample.ex", {10, 3}},
           "Function MyApp.recursive/1 has no local return"}
      }

      result = ReturnNoExit.render(entry, %Result{}, color?: false)

      # Reason block is only included if extract_reason_line finds a reason
      assert result.headline == "lib/sample.ex:10: MyApp.recursive/1 has no local return"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.recursive/1"))
    end

    test "includes suggestions" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 8,
        column: 2,
        text: "Function MyApp.infinite/0 has no local return",
        raw:
          {:warn_return_no_exit, {"lib/sample.ex", {8, 2}},
           "Function MyApp.infinite/0 has no local return"}
      }

      result = ReturnNoExit.render(entry, %Result{}, color?: false)

      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))
      assert Enum.any?(result.details, &String.contains?(&1, "Infinite loop"))
    end
  end
end
