defmodule Assay.Formatter.Warning.InvalidContractTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Warning.InvalidContract
  alias Assay.Formatter.Warning.Result

  describe "render/3" do
    test "builds a detailed warning when contract and success typing differ" do
      entry = %{
        relative_path: "lib/sample.ex",
        line: 12,
        raw:
          {:warn_contract_types,
           {~c"lib/sample.ex", {12, 6}},
           {:invalid_contract,
            [
              SampleModule,
              :foo,
              2,
              {:invalid_contract, {[1, 2], true}},
              "(integer()) :: integer()",
              "(atom()) :: atom()"
            ]}}
      }

      result = InvalidContract.render(entry, %Result{}, color?: false)

      assert result.headline ==
               "lib/sample.ex:12: SampleModule.foo/2 has an invalid contract"

      assert "Call: SampleModule.foo/2" in result.details

      assert Enum.any?(result.details, fn line ->
               String.contains?(line, "Invalid contract for 1st and 2nd arguments and the return type.")
             end)

      assert Enum.any?(result.details, fn line ->
               String.contains?(line, "Diff (expected -, actual +):")
             end)
    end

    test "falls back when relative context is missing" do
      entry = %{
        raw:
          {:warn_contract_types,
           nil,
           {:invalid_contract, [SampleModule, :bar, 1, :none, nil, nil]}},
        relative_path: nil,
        line: nil
      }

      result = InvalidContract.render(entry, %Result{}, color?: false)

      assert result.headline == "SampleModule.bar/1 has an invalid contract"

      assert Enum.any?(result.details, fn line ->
               String.contains?(line, "Contract cannot be verified.")
             end)
    end

    test "returns original result when parts do not match" do
      entry = %{
        raw: {:warn_contract_types, nil, {:invalid_contract, [:only, :three, :parts]}},
        relative_path: nil,
        line: nil
      }

      original = %Result{headline: "original", details: ["keep"]}

      assert InvalidContract.render(entry, original, color?: false) == original
    end

    test "summarizes argument-only and return-only mismatches" do
      entry_args = %{
        raw:
          {:warn_contract_types,
           nil,
           {:invalid_contract, [SampleModule, :baz, 1, {[2], false}, "(atom()) :: atom()", "(atom()) :: atom()"]}},
        relative_path: nil,
        line: nil
      }

      result_args = InvalidContract.render(entry_args, %Result{}, color?: false)

      assert Enum.any?(result_args.details, fn line ->
               String.contains?(line, "Invalid contract for 2nd argument.")
             end)

      entry_return = %{
        raw:
          {:warn_contract_types,
           nil,
           {:invalid_contract, [SampleModule, :baz, 1, {[], true}, nil, nil]}},
        relative_path: nil,
        line: nil
      }

      result_return = InvalidContract.render(entry_return, %Result{}, color?: false)

      assert Enum.any?(result_return.details, fn line ->
               String.contains?(line, "Invalid contract for the return type.")
             end)
    end

    test "handles unknown detail values" do
      entry = %{
        raw:
          {:warn_contract_types,
           nil,
           {:invalid_contract, [SampleModule, :baz, 1, :unexpected, nil, nil]}},
        relative_path: nil,
        line: nil
      }

      result = InvalidContract.render(entry, %Result{}, color?: false)

      assert Enum.any?(result.details, fn line ->
               String.contains?(line, "Contract contradicts the success typing")
             end)
    end
  end
end
