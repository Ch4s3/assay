defmodule Assay.Formatter.Warning.Matching do
  @moduledoc false

  alias Assay.Formatter.Suggestions
  alias Assay.Formatter.Warning
  alias Assay.Formatter.Warning.Handler
  alias Assay.Formatter.Warning.Result

  @behaviour Handler

  @impl true
  def render(entry, _result, _opts) do
    reason_line = Warning.extract_reason_line(entry)

    details =
      [
        Warning.reason_block(reason_line),
        [""],
        Suggestions.for_warning(:warn_matching, entry)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    headline = build_headline(entry)

    %Result{headline: headline, details: details}
  end

  defp build_headline(entry) do
    case {entry.relative_path, entry.line} do
      {relative, line} when not is_nil(relative) and not is_nil(line) ->
        "#{relative}:#{line}: pattern match will never succeed"

      _ ->
        "Pattern match will never succeed"
    end
  end
end
