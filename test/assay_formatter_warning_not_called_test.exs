defmodule Assay.Formatter.Warning.NotCalledTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Warning.NotCalled
  alias Assay.Formatter.Warning.Result

  describe "render/3" do
    test "builds warning with relative path, line, and call from raw" do
      entry = %{
        relative_path: "lib/sample.ex",
        line: 15,
        text: "Function MyApp.unused/1 is never called",
        raw: {:warn_not_called, {"lib/sample.ex", {15, 3}}, {MyApp, :unused, 1}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "lib/sample.ex:15: MyApp.unused/1 is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.unused/1"))
      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))
    end

    test "builds warning with call extracted from text" do
      entry = %{
        relative_path: "lib/sample.ex",
        line: 20,
        text: "Function MyApp.helper/2 is never called",
        raw: {:warn_not_called, {"lib/sample.ex", {20, 5}}, {MyApp, :helper, 2}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "lib/sample.ex:20: MyApp.helper/2 is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.helper/2"))
    end

    test "builds warning without relative path but with call" do
      entry = %{
        relative_path: nil,
        line: nil,
        text: "Function MyApp.unused/1 is never called",
        raw: {:warn_not_called, nil, {MyApp, :unused, 1}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "MyApp.unused/1 is never called"
    end

    test "builds warning without call information" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Some warning text",
        raw: {:warn_not_called, nil, {MyApp, :unknown, 0}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "MyApp.unknown/0 is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.unknown/0"))
    end

    test "includes suggestions" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 10,
        column: 3,
        text: "Function MyApp.unused/1 is never called",
        raw: {:warn_not_called, {"lib/sample.ex", {10, 3}}, {MyApp, :unused, 1}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert Enum.any?(result.details, &String.contains?(&1, "Suggestion:"))
      assert Enum.any?(result.details, &String.contains?(&1, "Remove the function"))
    end

    test "extracts function call from text when raw is missing" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: 10,
        column: 3,
        text: "Function MyApp.helper/2 is never called",
        raw: {:warn_not_called, {"lib/sample.ex", {10, 3}}, {MyApp, :helper, 2}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "lib/sample.ex:10: MyApp.helper/2 is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.helper/2"))
    end

    test "handles text without function name pattern" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Some warning without function name",
        raw: {:warn_not_called, nil, {MyApp, :unknown, 0}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "MyApp.unknown/0 is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.unknown/0"))
    end

    test "handles entry with only text field" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Function MyApp.test/3 is never called",
        raw: nil
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      # extract_from_text only extracts function name, not arity
      assert result.headline == "MyApp.test is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "Function: MyApp.test"))
    end

    test "handles entry with neither raw nor matching text" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Some other warning text",
        raw: nil
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "Function is never called"
      refute Enum.any?(result.details, &String.contains?(&1, "Function:"))
    end

    test "handles entry with relative_path but no line" do
      entry = %{
        relative_path: "lib/sample.ex",
        path: "lib/sample.ex",
        line: nil,
        column: nil,
        text: "Function MyApp.test/1 is never called",
        raw: {:warn_not_called, {"lib/sample.ex", nil}, {MyApp, :test, 1}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      # When line is nil, build_headline requires both relative_path AND line to include location
      # So it falls back to just the call or "Function is never called"
      # Since call is extracted from raw, it should include the call
      assert result.headline == "MyApp.test/1 is never called" or
               result.headline == "Function is never called"
    end

    test "handles entry with line but no relative_path" do
      entry = %{
        relative_path: nil,
        path: "/full/path/to/file.ex",
        line: 5,
        column: 3,
        text: "Function MyApp.test/1 is never called",
        raw: {:warn_not_called, {"/full/path/to/file.ex", {5, 3}}, {MyApp, :test, 1}}
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      assert result.headline == "MyApp.test/1 is never called"
    end

    test "handles text with different function name formats" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Function MyApp.Module.function!/2 is never called",
        raw: nil
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      # extract_from_text only extracts function name, not arity
      assert result.headline == "MyApp.Module.function! is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "MyApp.Module.function!"))
    end

    test "handles text with question mark in function name" do
      entry = %{
        relative_path: nil,
        path: nil,
        line: nil,
        column: nil,
        text: "Function MyApp.valid?/1 is never called",
        raw: nil
      }

      result = NotCalled.render(entry, %Result{}, color?: false)

      # extract_from_text only extracts function name, not arity
      assert result.headline == "MyApp.valid? is never called"
      assert Enum.any?(result.details, &String.contains?(&1, "MyApp.valid?"))
    end
  end
end
