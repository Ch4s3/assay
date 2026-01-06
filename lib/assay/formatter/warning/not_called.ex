defmodule Assay.Formatter.Warning.NotCalled do
  @moduledoc false

  alias Assay.Formatter.Suggestions
  alias Assay.Formatter.Warning
  alias Assay.Formatter.Warning.Handler
  alias Assay.Formatter.Warning.Result

  @behaviour Handler

  @impl true
  def render(entry, _result, _opts) do
    call = extract_function_call(entry)

    details =
      [
        call && ["Function: #{call}"],
        [""],
        Suggestions.for_warning(:warn_not_called, entry)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    headline = build_headline(entry, call)

    %Result{headline: headline, details: details}
  end

  defp extract_function_call(entry) do
    case entry do
      %{raw: {:warn_not_called, _loc, {module, fun, arity}}} ->
        Warning.format_call(module, fun) <> "/#{arity}"

      %{text: text} ->
        extract_from_text(text)

      _ ->
        nil
    end
  end

  defp extract_from_text(text) do
    # Pattern: "Function Module.fun/arity is never called"
    case Regex.run(~r/Function\s+([A-Z][\w\.]+\.[\w!?]+)\/(\d+)/, text) do
      [_, call, _arity] -> call
      _ -> nil
    end
  end

  defp build_headline(entry, call) do
    case {entry.relative_path, entry.line, call} do
      {relative, line, call}
      when not is_nil(relative) and not is_nil(line) and not is_nil(call) ->
        "#{relative}:#{line}: #{call} is never called"

      {nil, _, call} when not is_nil(call) ->
        "#{call} is never called"

      _ ->
        "Function is never called"
    end
  end
end
