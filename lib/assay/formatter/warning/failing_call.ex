defmodule Assay.Formatter.Warning.FailingCall do
  @moduledoc false

  alias Assay.Formatter.Suggestions
  alias Assay.Formatter.Warning
  alias Assay.Formatter.Warning.Handler
  alias Assay.Formatter.Warning.Result

  @behaviour Handler

  @impl true
  def render(%{raw: {:warn_failing_call, _loc, {:call, parts}}} = entry, result, opts) do
    case parts do
      [module, fun, actual, _positions, _mode, expected | _tail] ->
        call = Warning.format_call(module, fun)
        reason_line = Warning.extract_reason_line(entry)
        actual_lines = Warning.format_term_lines(actual)
        expected_lines = Warning.format_term_lines(expected)
        diff_lines = Warning.diff_lines(expected_lines, actual_lines, opts)
        color? = Keyword.get(opts, :color?, false)

        details =
          [
            ["Call: #{call}"],
            Warning.reason_block(reason_line),
            [""],
            Warning.value_block("Expected (success typing)", expected_lines,
              color?: color?,
              color: :red
            ),
            [""],
            Warning.value_block("Actual (call arguments)", actual_lines,
              color?: color?,
              color: :green
            ),
            Warning.diff_section(diff_lines, color?: color?),
            [""],
            Suggestions.for_warning(:warn_failing_call, entry)
          ]
          |> List.flatten()
          |> Enum.reject(&is_nil/1)

        headline =
          case entry.relative_path do
            nil -> "Failure in #{call}"
            relative -> "#{relative}:#{entry.line}: #{call} will fail"
          end

        %Result{headline: headline, details: details}

      _ ->
        result
    end
  end

  def render(_entry, result, _opts), do: result
end
