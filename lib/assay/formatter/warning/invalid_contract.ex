defmodule Assay.Formatter.Warning.InvalidContract do
  @moduledoc false

  alias Assay.Formatter.Warning
  alias Assay.Formatter.Warning.Handler
  alias Assay.Formatter.Warning.Result

  @behaviour Handler

  @impl true
  def render(
        %{raw: {:warn_contract_types, _loc, {:invalid_contract, parts}}} = entry,
        result,
        opts
      ) do
    case parts do
      [module, fun, arity, details, contract_text, success_text] ->
        render_invalid_contract(
          entry,
          module,
          fun,
          arity,
          details,
          contract_text,
          success_text,
          opts
        )

      _ ->
        result
    end
  end

  def render(_entry, result, _opts), do: result

  defp render_invalid_contract(
         entry,
         module,
         fun,
         arity,
         details,
         contract_text,
         success_text,
         opts
       ) do
    call = Warning.format_call(module, fun)
    call_with_arity = "#{call}/#{arity}"
    color? = Keyword.get(opts, :color?, false)
    contract_lines = Warning.format_term_lines(contract_text)
    success_lines = Warning.format_term_lines(success_text)
    diff_lines = Warning.diff_lines(contract_lines, success_lines, opts)
    reason_line = detail_summary(details)

    details_block =
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
        nil -> "#{call_with_arity} has an invalid contract"
        relative -> "#{relative}:#{entry.line}: #{call_with_arity} has an invalid contract"
      end

    %Result{headline: headline, details: details_block}
  end

  defp detail_summary(:none), do: "Contract cannot be verified."
  defp detail_summary("none"), do: "Contract cannot be verified."
  defp detail_summary(nil), do: "Contract cannot be verified."

  defp detail_summary({:invalid_contract, info}), do: detail_summary(info)

  defp detail_summary({args, return?}) when is_list(args) and is_boolean(return?) do
    segments =
      []
      |> maybe_add_args(args)
      |> maybe_add_return(return?)

    case segments do
      [] -> "Contract contradicts the success typing."
      [single] -> "Invalid contract for #{single}."
      _ -> "Invalid contract for #{Enum.join(segments, " and ")}."
    end
  end

  defp detail_summary(other), do: "Contract contradicts the success typing (#{inspect(other)})."

  defp maybe_add_args(acc, []), do: acc

  defp maybe_add_args(acc, args) do
    label =
      case args do
        [pos] -> "#{ordinal(pos)} argument"
        _ -> "#{Enum.map_join(args, " and ", &ordinal/1)} arguments"
      end

    acc ++ [label]
  end

  defp maybe_add_return(acc, false), do: acc
  defp maybe_add_return(acc, true), do: acc ++ ["the return type"]

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n), do: "#{n}th"
end
