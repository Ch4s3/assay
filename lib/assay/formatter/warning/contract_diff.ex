defmodule Assay.Formatter.Warning.ContractDiff do
  @moduledoc false

  alias Assay.Formatter.Warning
  alias Assay.Formatter.Warning.Handler
  alias Assay.Formatter.Warning.Result

  @behaviour Handler

  @codes [:warn_contract_not_equal, :warn_contract_subtype, :warn_contract_supertype]

  @impl true
  def render(%{code: code, raw: {tag, _loc, {kind, parts}}} = entry, result, opts)
      when code in @codes and tag == code do
    case parts do
      [module, fun, arity, contract_text, success_text] ->
        render_contract_diff(entry, module, fun, arity, contract_text, success_text, kind, opts)

      _ ->
        result
    end
  end

  def render(_entry, result, _opts), do: result

  defp render_contract_diff(entry, module, fun, arity, contract_text, success_text, kind, opts) do
    call = Warning.format_call(module, fun)
    call_with_arity = "#{call}/#{arity}"
    color? = Keyword.get(opts, :color?, false)
    contract_lines = Warning.format_term_lines(contract_text)
    success_lines = Warning.format_term_lines(success_text)
    diff_lines = Warning.diff_lines(contract_lines, success_lines, opts)
    reason_line = reason_description(kind)

    details =
      [
        ["Call: #{call_with_arity}"],
        Warning.reason_block(reason_line),
        [""],
        Warning.value_block("Contract (@spec)", contract_lines, color?: color?, color: :red),
        [""],
        Warning.value_block("Success typing", success_lines, color?: color?, color: :green),
        Warning.diff_section(diff_lines, color?: color?)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    headline =
      case entry.relative_path do
        nil -> "#{call_with_arity} #{headline_suffix(kind)}"
        relative -> "#{relative}:#{entry.line}: #{call_with_arity} #{headline_suffix(kind)}"
      end

    %Result{headline: headline, details: details}
  end

  defp reason_description(:contract_subtype),
    do: "Contract is narrower than the inferred success typing."

  defp reason_description(:contract_supertype),
    do: "Contract is more permissive than the success typing."

  defp reason_description(_),
    do: "Contract differs from the inferred success typing."

  defp headline_suffix(:contract_subtype), do: "contract is a subtype of the success typing"
  defp headline_suffix(:contract_supertype), do: "contract is a supertype of the success typing"
  defp headline_suffix(_), do: "contract differs from the success typing"
end
