defmodule Assay.Formatter.Warning.ContractDiffTest do
  use ExUnit.Case, async: true

  alias Assay.Formatter.Warning.ContractDiff
  alias Assay.Formatter.Warning.Result

  test "renders contract subtype with relative path" do
    entry = %{
      code: :warn_contract_subtype,
      raw:
        {:warn_contract_subtype, {"lib/foo.ex", 5},
         {:contract_subtype, [Foo, :bar, 1, "(integer())", "(number())"]}},
      relative_path: "lib/foo.ex",
      line: 5
    }

    result = ContractDiff.render(entry, %Result{}, color?: false)

    assert result.headline ==
             "lib/foo.ex:5: Foo.bar/1 contract is a subtype of the success typing"

    assert Enum.any?(result.details, &String.contains?(&1, "Contract is narrower"))
    assert Enum.any?(result.details, &String.contains?(&1, "Contract (@spec)"))
  end

  test "renders contract supertype without relative path" do
    entry = %{
      code: :warn_contract_supertype,
      raw:
        {:warn_contract_supertype, nil,
         {:contract_supertype, [Foo, :bar, 2, "(integer())", "(number())"]}},
      relative_path: nil,
      line: nil
    }

    result = ContractDiff.render(entry, %Result{}, color?: false)

    assert result.headline == "Foo.bar/2 contract is a supertype of the success typing"
    assert Enum.any?(result.details, &String.contains?(&1, "Contract is more permissive"))
  end

  test "returns existing result when parts are unexpected" do
    entry = %{
      code: :warn_contract_not_equal,
      raw: {:warn_contract_not_equal, nil, {:contract_mismatch, [Foo, :bar]}},
      relative_path: "lib/foo.ex",
      line: 1
    }

    base = %Result{headline: "base", details: ["detail"]}
    assert ContractDiff.render(entry, base, color?: false) == base
  end
end
