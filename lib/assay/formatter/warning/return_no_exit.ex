defmodule Assay.Formatter.Warning.ReturnNoExit do
  @moduledoc false

  alias Assay.Formatter.Suggestions
  alias Assay.Formatter.Warning
  alias Assay.Formatter.Warning.Handler
  alias Assay.Formatter.Warning.Result

  @behaviour Handler

  @impl true
  def render(entry, _result, _opts) do
    reason_line = Warning.extract_reason_line(entry)
    call = extract_function_call(entry)

    details =
      [
        call && ["Function: #{call}"],
        Warning.reason_block(reason_line),
        [""],
        Suggestions.for_warning(:warn_return_no_exit, entry)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    headline = build_headline(entry, call)

    %Result{headline: headline, details: details}
  end

  defp extract_function_call(entry) do
    # Try to extract from text (warn_return_no_exit raw structure is {code, location, message_string})
    case entry do
      %{text: text} ->
        extract_from_text(text)

      _ ->
        nil
    end
  end

  defp extract_from_text(text) do
    # Pattern: "Function Module.fun/arity has no local return"
    case Regex.run(~r/Function\s+([A-Z][\w\.]+\.[\w!?]+)\/(\d+)/, text) do
      [_, call, arity] -> "#{call}/#{arity}"
      _ -> nil
    end
  end

  defp build_headline(entry, call) do
    case {entry.relative_path, entry.line, call} do
      {relative, line, call}
      when not is_nil(relative) and not is_nil(line) and not is_nil(call) ->
        "#{relative}:#{line}: #{call} has no local return"

      {nil, _, call} when not is_nil(call) ->
        "#{call} has no local return"

      _ ->
        "Function has no local return"
    end
  end
end
